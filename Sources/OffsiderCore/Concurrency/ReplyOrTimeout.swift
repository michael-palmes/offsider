import Foundation

/// True for exactly one caller, which resumes the continuation.
public final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true

    public init() {}

    public func claim() -> Bool {
        lock.withLock {
            let wasPending = pending
            pending = false
            return wasPending
        }
    }
}

/// The reply `send` hands back, or `timedOut` once `seconds` pass on `queue` first; whichever comes second is ignored.
public func replyOrTimeout<T>(
    within seconds: Double, timedOut: T, on queue: DispatchQueue = .global(qos: .userInitiated), _ send: (@escaping @Sendable (T) -> Void) -> Void
) async -> T {
    let once = OnceFlag()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        send { reply in
            if once.claim() { continuation.resume(returning: reply) }
        }
        queue.asyncAfter(deadline: .now() + seconds) {
            if once.claim() { continuation.resume(returning: timedOut) }
        }
    }
}
