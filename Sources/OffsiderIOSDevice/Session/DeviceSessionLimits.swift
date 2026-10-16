import Foundation
import OffsiderCore

/// The bounds the session broker holds every client and request to.
public enum DeviceSessionLimits {
    /// Connections served at once; the next is refused with a framed `session_failed` reply.
    public static let maxClients = 8
    /// How long a frame body may take to arrive once its header has.
    public static let bodyTimeout: Duration = .seconds(10)
    /// One pause in a touch or key request.
    public static let maxWaitSeconds: Double = 30
    /// Every pause in one request together.
    public static let maxRequestSeconds: Double = 60
    public static let maxSteps = 4096
    public static let maxIdleSeconds = 3600
    /// A broker this old stops at its next idle moment, so a long-lived one is renewed.
    public static let maxLifetime: Duration = .seconds(12 * 3600)
    /// How often a running broker re-reads its device's allowance and checks the device is still on USB.
    public static let recheckInterval: Duration = .seconds(30)
    /// How long a new client may stay silent before its first request, whatever the idle setting.
    public static let firstRequestTimeout: Duration = .seconds(10)
    /// Pinned to `Drag.maxSteps` by a test.
    public static let maxSwipeSteps = PixelMath.maxSwipeSteps
    public static let maxSwipeSeconds: Double = 30
    public static let maxFrameDimension = PixelMath.maxSide

    /// The consumer-page usages `HardwareButton` maps to on a device: home, lock and side, Siri.
    public static let buttonUsages: Set<UInt64> = Set(HardwareButton.allCases.compactMap(\.deviceUsage))

    public static func allowsButton(page: UInt64, code: UInt64) -> Bool {
        page == DTUHIDMessage.consumerUsagePage && buttonUsages.contains(code)
    }

    /// Bytes in a BGRA frame of this size; nil when a side is outside 1 to 16,384 or the product overflows.
    public static func bgraByteCount(width: Int, height: Int) -> Int? {
        PixelMath.byteCount(width: width, height: height)
    }

    /// Idle seconds clamped to `1...maxIdleSeconds`.
    public static func clampedIdle(_ seconds: Int) -> Int {
        min(max(seconds, 1), maxIdleSeconds)
    }

    /// Refuses a request with too many steps, a pause that is not finite or is outside 0 to 30 s, or pauses over 60 s together.
    public static func checkBudget(_ steps: [DeviceSessionStep]) throws {
        guard steps.count <= maxSteps else {
            throw IOSDeviceError(.sessionFailed, "The input has \(steps.count) steps, more than the device session's \(maxSteps).")
        }
        var total = 0.0
        for step in steps where step.kind == .wait {
            guard let seconds = step.seconds, seconds.isFinite, seconds >= 0, seconds <= maxWaitSeconds else {
                throw IOSDeviceError(.sessionFailed, "A wait in the input steps is outside 0 to \(Int(maxWaitSeconds)) s.")
            }
            total += seconds
        }
        guard total <= maxRequestSeconds else {
            throw IOSDeviceError(.sessionFailed, "The waits in one input request add up to more than \(Int(maxRequestSeconds)) s. Split the input into shorter commands.")
        }
    }
}
