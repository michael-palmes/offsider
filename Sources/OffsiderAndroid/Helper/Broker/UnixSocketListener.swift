import Darwin
import Foundation
import OffsiderCore

/// Why the broker could not listen, or a command could not reach or start one; the command then starts its own helper.
struct HelperBrokerUnavailable: Error, Equatable, Sendable, CustomStringConvertible {
    let detail: String

    var description: String { detail }
}

/// The broker's `UnixSocket`, accepting only this user's processes that `admits` accepts, on a queue of its own.
final class UnixSocketListener: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let identity: [UInt64]?
    private let admits: @Sendable (Int32) -> Bool
    private let queue = DispatchQueue(label: "offsider.helper-broker.accept")
    private let lock = NSLock()
    private var closed = false

    init(path: String, uid: uid_t = getuid(), admits: @escaping @Sendable (Int32) -> Bool) throws {
        self.path = path
        self.admits = admits
        do {
            descriptor = try UnixSocket.listen(at: path, uid: uid)
        } catch let error as UnixSocketError {
            throw HelperBrokerUnavailable(error)
        } catch {
            throw HelperBrokerUnavailable(detail: "the sessions folder is not private: \(error)")
        }
        // Non-blocking, so a client that leaves between the poll and the accept cannot stall the queue.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        identity = UnixSocket.identity(path)
    }

    deinit { close() }

    /// The next client within `timeout`, nil when none came; another user's client, or one `admits` refuses, is closed unread.
    func accept(timeout: Duration, uid: uid_t = getuid()) async -> Int32? {
        let milliseconds = Int32(clamping: timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: acceptNow(waitingMs: milliseconds, uid: uid))
            }
        }
    }

    private func acceptNow(waitingMs: Int32, uid: uid_t) -> Int32? {
        guard !isClosed else { return nil }
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, waitingMs) > 0 else { return nil }
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { return nil }
        guard UnixSocket.isSameUser(client, uid: uid), admits(client) else {
            Darwin.close(client)
            return nil
        }
        return client
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Stops listening and removes the socket, unless another broker has since replaced it.
    func close() {
        let first = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard first else { return }
        queue.sync { Darwin.close(descriptor) }
        UnixSocket.remove(path, ifIdentity: identity)
    }
}

extension HelperBrokerUnavailable {
    init(_ error: UnixSocketError) {
        switch error {
        case .pathTooLong(let path): detail = "the socket path \(path) is longer than 103 bytes"
        case .alreadyServed(let path): detail = "another broker already listens on \(path)"
        case .notOwnedSocket(let path): detail = "\(path) is not a socket this user owns, so Offsider will not replace it"
        case .system(let operation, let path, let code): detail = "could not \(operation) \(path): \(String(cString: strerror(code)))"
        }
    }
}
