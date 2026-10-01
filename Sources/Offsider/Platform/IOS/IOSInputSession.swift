import Foundation
import OffsiderCore

@MainActor
final class IOSInputSession: InputSession {
    let hidSession: HIDInteractor.Session
    private let logger: OffsiderLogger

    init(hidSession: HIDInteractor.Session, logger: OffsiderLogger) {
        self.hidSession = hidSession
        self.logger = logger
    }

    var device: DeviceID {
        DeviceID(rawValue: hidSession.simulatorUDID, platform: .ios)
    }

    func perform(_ event: InputEvent) async throws {
        try await HIDInteractor.performHIDEvent(event.hidEvent, in: hidSession, logger: logger)
    }

    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        try await HIDInteractor.performPhysicalTap(
            at: point,
            preDelay: preDelay,
            postDelay: postDelay,
            in: hidSession,
            logger: logger
        )
    }

    func close() async {
        await HIDInteractor.closeSession(hidSession)
    }
}
