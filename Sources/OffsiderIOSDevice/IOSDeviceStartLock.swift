import Darwin
import Foundation
import OffsiderCore

/// An exclusive `flock` held while one command starts a runner or broker; closing it, or the process exiting, releases it.
final class IOSDeviceStartLock: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit { release() }

    /// Polls every `poll` until `timeout`, then throws `busy()`; the holder writes its owner line for diagnostics.
    static func acquire(_ path: String, timeout: TimeInterval, poll: Duration, busy: () -> Error) async throws -> IOSDeviceStartLock {
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(path)
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while !(try tryLock(descriptor, path: path)) {
                guard Date() < deadline else { throw busy() }
                try await Task.sleep(for: poll)
            }
            let owner = Array(Self.owner(getpid()).utf8)
            guard ftruncate(descriptor, 0) == 0, pwrite(descriptor, owner, owner.count, 0) == owner.count else {
                throw PrivateDirectoryError(.system(operation: "write", code: errno), path: path)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return IOSDeviceStartLock(path: path, descriptor: descriptor)
    }

    /// Idempotent; the file stays, since unlinking a `flock` file races with the next opener.
    func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// The holder's pid and process start time.
    static func owner(_ pid: Int32) -> String {
        "\(pid) \(RunnerProcessIdentity.of(pid: pid)?.startTime ?? 0)\n"
    }

    private static func tryLock(_ descriptor: Int32, path: String) throws -> Bool {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { return false }
            throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: path)
        }
        return true
    }
}
