import Darwin
import Foundation
import OffsiderCore
import Testing

/// A private root under the temp directory, removed by the caller.
func makePrivateLockRoot() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-lock-test-\(UUID().uuidString)")
    try OffsiderPrivateDirectory.ensurePrivateDirectory(path, uid: getuid())
    return path
}

private final class FakeLockClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero
    private(set) var sleeps = 0

    var now: ContinuousClock.Instant { lock.withLock { start + elapsed } }

    func sleep(_ duration: Duration) {
        lock.withLock {
            elapsed += duration
            sleeps += 1
        }
    }
}

@Suite("Device lock")
struct DeviceLockTests {
    let key = DeviceLockKey(platform: .ios, id: UUID().uuidString)

    @Test("a second claim on a held device fails at once and names the holder's pid and command")
    func secondClaimFails() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let held = try await DeviceLock.acquire(key, command: "batch", wait: nil, root: root)
        defer { held.release() }

        let error = await #expect(throws: DeviceBusy.self) {
            _ = try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root)
        }
        #expect(error?.holder?.pid == getpid())
        #expect(error?.holder?.command == "batch")
        #expect(error?.reason == .deviceBusy)
        #expect(error?.exitCode == .deviceBusy)
        #expect(error?.failureMessage.contains("pid \(getpid()) (offsider batch") == true)
        #expect(error?.failureMessage.contains("--wait-lock <seconds>") == true)
    }

    @Test("a claim on another device succeeds while one is held")
    func otherDeviceIsFree() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let held = try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root)
        defer { held.release() }
        let other = try await DeviceLock.acquire(DeviceLockKey(platform: .android, id: "emulator-5554"), command: "tap", wait: nil, root: root)
        other.release()
    }

    @Test("a released device can be claimed again")
    func releasedDeviceCanBeClaimed() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root).release()
        try await DeviceLock.acquire(key, command: "swipe", wait: nil, root: root).release()
    }

    @Test("--wait-lock waits for the holder to release")
    func waitSucceedsAfterRelease() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let held = try await DeviceLock.acquire(key, command: "batch", wait: nil, root: root)
        let releaser = Task {
            try await Task.sleep(for: .milliseconds(100))
            held.release()
        }
        let started = ContinuousClock.now
        let lock = try await DeviceLock.acquire(key, command: "tap", wait: .seconds(20), root: root)
        lock.release()
        try await releaser.value
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test("--wait-lock gives up at its bound with device_busy, polling every 50 ms")
    func waitGivesUp() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let held = try await DeviceLock.acquire(key, command: "batch", wait: nil, root: root)
        defer { held.release() }
        let clock = FakeLockClock()

        let error = await #expect(throws: DeviceBusy.self) {
            _ = try await DeviceLock.acquire(
                key, command: "tap", wait: .seconds(1), root: root,
                now: { clock.now }, sleep: { clock.sleep($0) }
            )
        }
        #expect(error?.waited == .seconds(1))
        #expect(error?.failureMessage.contains("after waiting 1 s") == true)
        #expect(clock.sleeps == 20)
    }

    @Test("the lock file records the holder and is 0600 inside a 0700 directory")
    func lockFileModes() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let lock = try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root)
        defer { lock.release() }

        var info = stat()
        #expect(stat(lock.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat((lock.path as NSString).deletingLastPathComponent, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        let holder = DeviceLockHolder.parse(try String(contentsOfFile: lock.path, encoding: .utf8))
        #expect(holder?.pid == getpid())
        #expect(holder?.command == "tap")
        #expect(holder?.startedAt != nil)
    }

    @Test("a symlink in place of a lock file is refused")
    func symlinkRefused() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let locks = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.locksDirectoryName, root: root)
        let target = (root as NSString).appendingPathComponent("elsewhere")
        FileManager.default.createFile(atPath: target, contents: Data(), attributes: [.posixPermissions: 0o600])
        try FileManager.default.createSymbolicLink(atPath: (locks as NSString).appendingPathComponent(key.fileName), withDestinationPath: target)

        let error = await #expect(throws: PrivateDirectoryError.self) {
            _ = try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root)
        }
        #expect(error?.reason == .privateDirectoryUnsafe)
    }

    @Test("a group-writable lock directory is refused")
    func openDirectoryRefused() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let locks = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.locksDirectoryName, root: root)
        #expect(chmod(locks, 0o770) == 0)

        let error = await #expect(throws: PrivateDirectoryError.self) {
            _ = try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root)
        }
        #expect(error?.kind == .unsafeDirectory)
    }

    @Test("a child process does not inherit a claim")
    func childDoesNotInherit() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let lock = try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root)

        // posix_spawn without CLOEXEC_DEFAULT passes every descriptor not marked close-on-exec.
        var pid: pid_t = 0
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("10"), nil]
        defer { arguments.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sleep", nil, nil, arguments, environ) == 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        lock.release()
        // A short wait covers the child closing close-on-exec descriptors as its exec completes; an inherited lock would last 10 s.
        let again = try await DeviceLock.acquire(key, command: "tap", wait: .seconds(1), root: root)
        again.release()
        #expect(kill(pid, 0) == 0)
    }

    @Test("a lock file the holder has not written yet still refuses, naming no pid")
    func emptyHolder() {
        let busy = DeviceBusy(device: "emulator-5554", command: "tap", holder: DeviceLockHolder.parse(""), waited: nil)
        #expect(busy.holder == nil)
        #expect(busy.failureMessage == "Device emulator-5554 is in use by another Offsider command. Retry when it finishes, or pass --wait-lock <seconds>.")
    }
}

@Suite("Offsider private directory")
struct OffsiderPrivateDirectoryTests {
    @Test("the root ignores TMPDIR when the per-user temp directory can be made private")
    func rootPrefersUserTemp() throws {
        let userTemp = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: userTemp) }
        let root = OffsiderPrivateDirectory.resolveRoot(uid: getuid(), userTemp: userTemp, fallbackTemp: "/private/tmp/agent-sandbox")
        #expect(root == (userTemp as NSString).appendingPathComponent("offsider-\(getuid())"))
    }

    @Test("the root falls back to TMPDIR when the per-user temp directory cannot be used")
    func rootFallsBack() throws {
        let fallback = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: fallback) }
        let root = OffsiderPrivateDirectory.resolveRoot(uid: getuid(), userTemp: "/nonexistent/offsider-blocked", fallbackTemp: fallback)
        #expect(root.hasSuffix("/offsider-\(getuid())"))
        #expect(root.hasPrefix(URL(fileURLWithPath: fallback).resolvingSymlinksInPath().path))
    }

    @Test("an open or symlinked directory is refused and a missing one is created 0700")
    func directoryChecks() throws {
        let base = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let created = (base as NSString).appendingPathComponent("new")
        try OffsiderPrivateDirectory.ensurePrivateDirectory(created, uid: getuid())
        var info = stat()
        #expect(lstat(created, &info) == 0 && info.st_mode & 0o777 == 0o700)

        let open = (base as NSString).appendingPathComponent("open")
        #expect(mkdir(open, 0o755) == 0 && chmod(open, 0o755) == 0)
        #expect(throws: PrivateDirectoryError(.unsafeDirectory, path: open)) {
            try OffsiderPrivateDirectory.ensurePrivateDirectory(open, uid: getuid())
        }

        let link = (base as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: created)
        #expect(throws: PrivateDirectoryError(.unsafeDirectory, path: link)) {
            try OffsiderPrivateDirectory.ensurePrivateDirectory(link, uid: getuid())
        }

        #expect(throws: PrivateDirectoryError(.unsafeDirectory, path: created)) {
            try OffsiderPrivateDirectory.ensurePrivateDirectory(created, uid: getuid() + 1)
        }
    }

    @Test("a private file is opened close-on-exec and a group-readable one is refused")
    func fileChecks() throws {
        let base = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = (base as NSString).appendingPathComponent("file")
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(path)
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        Darwin.close(descriptor)

        #expect(chmod(path, 0o640) == 0)
        #expect(throws: PrivateDirectoryError(.unsafeFile, path: path)) {
            _ = try OffsiderPrivateDirectory.openPrivateFile(path)
        }
    }
}
