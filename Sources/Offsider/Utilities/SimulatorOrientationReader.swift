import Foundation
import FBSimulatorControl

@MainActor
struct SimulatorOrientationReader {
    static func currentOrientation(
        simulatorUDID: String,
        screenID: Int = 1,
        logger: OffsiderLogger
    ) async -> SimulatorOrientation? {
        do {
            guard let simulator = try await cachedSimulator(udid: simulatorUDID, logger: logger) else {
                logger.info().log("Orientation probe: simulator \(simulatorUDID) not found")
                return nil
            }
            return await currentOrientation(of: simulator, screenID: screenID, logger: logger)
        } catch {
            logger.info().log("Orientation probe failed: \(error)")
            return nil
        }
    }

    /// `screenID` is the active display's, from the device type profile; 1 on a device with one display.
    static func currentOrientation(of simulator: FBSimulator, screenID: Int = 1, logger: OffsiderLogger) async -> SimulatorOrientation? {
        await Timings.measure("orientation") {
            do {
                try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
            } catch {
                logger.info().log("Orientation probe failed: \(error)")
                return nil
            }
            guard let device = sendObject(simulator, selector: "device") else {
                logger.info().log("Orientation probe: simulator device unavailable")
                return nil
            }
            // SimulatorKit's screen can be briefly unavailable on a busy Mac, so give it a few tries.
            for attempt in 1...screenReadAttempts {
                if let orientation = readOrientation(from: device, screenID: screenID, logger: logger) {
                    return orientation
                }
                if attempt < screenReadAttempts {
                    try? await Task.sleep(for: screenReadRetryDelay)
                }
            }
            return nil
        }
    }

    private static let screenReadAttempts = 4
    private static let screenReadRetryDelay: Duration = .milliseconds(200)

    private static func readOrientation(from device: AnyObject, screenID: Int, logger: OffsiderLogger) -> SimulatorOrientation? {
        guard let screenClass = NSClassFromString("SimulatorKit.SimDeviceScreen") as? NSObject.Type else {
            logger.info().log("Orientation probe: SimulatorKit.SimDeviceScreen unavailable")
            return nil
        }

        let initSelector = NSSelectorFromString("initWithDevice:screenID:")
        guard let allocated = allocate(screenClass) else {
            logger.info().log("Orientation probe: SimDeviceScreen allocation failed")
            return nil
        }
        guard let initMethod = allocated.method(for: initSelector) else {
            logger.info().log("Orientation probe: initWithDevice:screenID: unavailable")
            return nil
        }

        typealias InitFunction = @convention(c) (AnyObject, Selector, AnyObject, Int) -> AnyObject
        let initFunction = unsafeBitCast(initMethod, to: InitFunction.self)
        let screenDevice = initFunction(allocated, initSelector, device, screenID)

        guard let screen = sendObject(screenDevice, selector: "screen") else {
            logger.info().log("Orientation probe: screen unavailable")
            return nil
        }

        guard let properties = sendObject(screen, selector: "screenProperties") else {
            logger.info().log("Orientation probe: screenProperties unavailable")
            return nil
        }

        guard let rawOrientation = sendUInt32(properties, selector: "uiOrientation") else {
            logger.info().log("Orientation probe: uiOrientation unavailable")
            return nil
        }

        logger.info().log("Orientation probe: screen \(screenID) uiOrientation=\(rawOrientation)")
        return mapUIOrientation(rawOrientation)
    }

    private static func allocate(_ objectClass: NSObject.Type) -> AnyObject? {
        let selector = NSSelectorFromString("alloc")
        guard let method = class_getClassMethod(objectClass, selector) else {
            return nil
        }

        typealias Function = @convention(c) (AnyClass, Selector) -> AnyObject?
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        return function(objectClass, selector)
    }

    private static func sendObject(_ target: AnyObject, selector selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard let object = target as? NSObject,
              object.responds(to: selector),
              let method = object.method(for: selector) else {
            return nil
        }

        typealias Function = @convention(c) (AnyObject, Selector) -> AnyObject?
        let function = unsafeBitCast(method, to: Function.self)
        return function(target, selector)
    }

    private static func sendUInt32(_ target: AnyObject, selector selectorName: String) -> UInt32? {
        let selector = NSSelectorFromString(selectorName)
        guard let object = target as? NSObject,
              object.responds(to: selector),
              let method = object.method(for: selector) else {
            return nil
        }

        typealias Function = @convention(c) (AnyObject, Selector) -> UInt32
        let function = unsafeBitCast(method, to: Function.self)
        return function(target, selector)
    }

    private static func mapUIOrientation(_ rawOrientation: UInt32) -> SimulatorOrientation? {
        switch rawOrientation {
        case 1:
            return .portrait
        case 2:
            return .portraitUpsideDown
        case 3:
            return .landscape
        case 4:
            return .landscapeFlipped
        default:
            return nil
        }
    }
}
