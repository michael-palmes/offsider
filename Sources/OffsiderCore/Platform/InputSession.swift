import Foundation

public enum TapTiming {
    public static let defaultHoldDuration: TimeInterval = 0.1
}

/// One open input connection to a device; class-bound so a session can own its transport.
@MainActor
public protocol InputSession: AnyObject {
    var device: DeviceID { get }
    func perform(_ event: InputEvent) async throws
    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws
    func close() async
}

extension InputSession {
    /// Down, hold, up. After a failure that follows the down, only a best-effort up is sent, never a second down.
    public func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        if let preDelay, preDelay > 0 {
            try await Task.sleep(for: .seconds(preDelay))
        }

        let touchDown = InputEvent.touch(direction: .down, x: point.x, y: point.y)
        let touchUp = InputEvent.touch(direction: .up, x: point.x, y: point.y)
        var didTouchDown = false

        do {
            try await perform(touchDown)
            didTouchDown = true
            try await Task.sleep(for: .seconds(TapTiming.defaultHoldDuration))
            try await perform(touchUp)
            didTouchDown = false
        } catch {
            if didTouchDown {
                try? await perform(touchUp)
            }
            throw error
        }

        if let postDelay, postDelay > 0 {
            try await Task.sleep(for: .seconds(postDelay))
        }
    }
}
