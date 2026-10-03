import FBSimulatorControl
import Foundation
import OffsiderCore

/// Input on a foldable's display that is not the main screen: touches go to that display's touchscreen, as idb only reaches the main one.
/// Points arrive in main-screen points (from `deviceCoordinates`) and leave as the same fractions idb would send, with the display's screen ID as the target.
@MainActor
final class IOSDisplayInputSession: InputSession {
    let device: DeviceID
    private let simulator: FBSimulator
    private let screenID: UInt64
    private let mainSize: (width: Double, height: Double)
    private let logger: OffsiderLogger
    private var digitizer: SimulatorDTUHID?
    private var idbSession: HIDInteractor.Session?
    private var contact = DTUHIDContact()

    init(device: DeviceID, simulator: FBSimulator, screenID: UInt64, mainSize: (width: Double, height: Double), logger: OffsiderLogger) {
        self.device = device
        self.simulator = simulator
        self.screenID = screenID
        self.mainSize = mainSize
        self.logger = logger
    }

    func perform(_ event: InputEvent) async throws {
        let hidEvent = try event.hidEvent()
        guard Self.isTouchOnly(hidEvent) else {
            try await HIDInteractor.performHIDEvent(hidEvent, in: try await idb(), logger: logger)
            return
        }
        try await sendTouches(hidEvent)
    }

    func close() async {
        await digitizer?.close()
        digitizer = nil
        if let idbSession { await HIDInteractor.closeSession(idbSession) }
        idbSession = nil
    }

    private func sendTouches(_ event: FBSimulatorHIDEvent) async throws {
        switch event {
        case let .touch(direction, x, y):
            let link = try await connectedDigitizer()
            let phase = contact.phase(touchingDown: direction == .down)
            await link.send(DTUHIDMessage.touch(x: x / mainSize.width, y: y / mainSize.height, phase: phase, target: screenID))
        case let .delay(seconds):
            try await Task.sleep(for: .seconds(max(0, seconds)))
        case let .composite(events):
            for event in events { try await sendTouches(event) }
        default:
            throw CLIError(errorDescription: Self.unsupported)
        }
    }

    private func connectedDigitizer() async throws -> SimulatorDTUHID {
        if let digitizer { return digitizer }
        do {
            let link = try await Timings.measure("digitizer") {
                try await SimulatorDTUHID.connect(to: simulator, service: DTUHIDMessage.digitizerService)
            }
            digitizer = link
            return link
        } catch {
            logger.info().log("Display digitizer: \(error)")
            throw CLIError(errorDescription: Self.unsupported)
        }
    }

    private func idb() async throws -> HIDInteractor.Session {
        if let idbSession { return idbSession }
        let session = try await HIDInteractor.makeSession(for: device.rawValue, logger: logger)
        idbSession = session
        return session
    }

    static let unsupported = "Input on the iPhone Duo's inner display is not supported on this simulator; fold the simulator to use the cover display."

    /// Touches and delays only; anything else (keys, buttons) is not tied to a display and goes through idb.
    nonisolated static func isTouchOnly(_ event: FBSimulatorHIDEvent) -> Bool {
        switch event {
        case .touch, .delay: return true
        case let .composite(events): return events.allSatisfy(isTouchOnly)
        default: return false
        }
    }
}
