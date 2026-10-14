import Foundation
import FBSimulatorControl
import OffsiderCore

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

    /// Readings one scope shares, such as a gesture preset sizing itself to the screen and then mapping its points; nil reads every time.
    @TaskLocal static var sharedReadings: SharedReadings?

    @MainActor
    final class SharedReadings {
        fileprivate var values: [String: SimulatorOrientation] = [:]
    }

    /// `screenID` is the active display's, from the device type profile; 1 on a device with one display.
    static func currentOrientation(of simulator: FBSimulator, screenID: Int = 1, logger: OffsiderLogger) async -> SimulatorOrientation? {
        let key = "\(simulator.udid)#\(screenID)"
        if let known = sharedReadings?.values[key] {
            return known
        }
        let read = await probeOrientation(of: simulator, screenID: screenID, logger: logger)
        if let read {
            sharedReadings?.values[key] = read
        }
        return read
    }

    private static func probeOrientation(of simulator: FBSimulator, screenID: Int, logger: OffsiderLogger) async -> SimulatorOrientation? {
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
        do {
            try PrivateAPIGuard.requireMethod(object_getClass(screenClass)!, NSSelectorFromString("alloc"), encoding: Encodings.alloc, framework: "SimulatorKit")
            try PrivateAPIGuard.requireMethod(screenClass, initSelector, encoding: Encodings.initWithDeviceScreenID, framework: "SimulatorKit")
            try PrivateAPIGuard.requireMethod(screenClass, NSSelectorFromString("screen"), encoding: Encodings.screen, framework: "SimulatorKit")
        } catch {
            logger.info().log("Orientation probe: \(error.localizedDescription)")
            return nil
        }
        guard let screenID = UInt32(exactly: screenID), let screenDevice = makeScreen(screenClass, device: device, screenID: screenID, selector: initSelector) else {
            logger.info().log("Orientation probe: SimDeviceScreen could not be made for screen \(screenID)")
            return nil
        }

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

    /// The type encodings (offsets stripped) SimulatorKit has with Xcode 27; checked before each cast below.
    enum Encodings {
        static let alloc = "@@:"
        static let initWithDeviceScreenID = "@@:@I"
        static let screen = "@@:"
    }

    /// `[[SimDeviceScreen alloc] initWithDevice:screenID:]` with ownership balanced: `alloc` hands over +1, `init` consumes it and returns +1, or nil having released it.
    private static func makeScreen(_ screenClass: NSObject.Type, device: AnyObject, screenID: UInt32, selector: Selector) -> AnyObject? {
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(screenClass, allocSelector), let initMethod = class_getInstanceMethod(screenClass, selector) else {
            return nil
        }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias Initialise = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject, UInt32) -> UnsafeMutableRawPointer?
        guard let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(screenClass, allocSelector) else { return nil }
        let initialised = unsafeBitCast(method_getImplementation(initMethod), to: Initialise.self)(allocated, selector, device, screenID)
        return initialised.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
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

    static func mapUIOrientation(_ rawOrientation: UInt32) -> SimulatorOrientation? {
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
