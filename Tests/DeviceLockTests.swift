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

/// `/bin/sleep 10`, keeping `inherited` open across its exec when given; plain `posix_spawn` passes every descriptor not marked close-on-exec.
private func spawnSleep(inheriting inherited: Int32? = nil) throws -> pid_t {
    var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let inherited { posix_spawn_file_actions_addinherit_np(&actions, inherited) }
    var pid: pid_t = 0
    let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("10"), nil]
    defer { arguments.forEach { free($0) } }
    try #require(posix_spawn(&pid, "/bin/sleep", &actions, nil, arguments, environ) == 0)
    return pid
}

private func reap(_ pid: pid_t) {
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
}

/// The descriptor this process holds open on `path`, matched by device and inode.
private func openDescriptor(for path: String) -> Int32? {
    var target = stat()
    guard stat(path, &target) == 0 else { return nil }
    var info = stat()
    return (0..<getdtablesize()).first { fstat($0, &info) == 0 && info.st_dev == target.st_dev && info.st_ino == target.st_ino }
}

/// Whether `pid` holds a descriptor open on `path`, read through libproc.
private func process(_ pid: pid_t, holds path: String) -> Bool {
    var target = stat()
    guard stat(path, &target) == 0 else { return false }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
    return descriptors.prefix(max(0, Int(bytes)) / stride).contains { descriptor in
        guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return false }
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return false }
        let file = info.pvip.vip_vi.vi_stat
        return file.vst_dev == UInt32(bitPattern: target.st_dev) && file.vst_ino == target.st_ino
    }
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

    @Test("a reader sees the live holder without taking the lock, and nothing once it is released")
    func currentHolder() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(DeviceLock.currentHolder(key, root: root, isOffsider: { _ in true }) == nil)
        let held = try await DeviceLock.acquire(key, command: "wait", wait: nil, root: root)

        let holder = DeviceLock.currentHolder(key, root: root, isOffsider: { _ in true })
        #expect(holder?.pid == getpid())
        #expect(holder?.command == "wait")
        #expect(DeviceLock.currentHolder(key, root: root, isOffsider: { _ in false }) == nil)
        let second = try await DeviceLock.acquire(DeviceLockKey(platform: .android, id: "emulator-5554"), command: "tap", wait: nil, root: root)
        second.release()
        let busy = await #expect(throws: DeviceBusy.self) { _ = try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root) }
        #expect(busy?.holder?.command == "wait")

        held.release()
        #expect(DeviceLock.currentHolder(key, root: root, isOffsider: { _ in true }) == nil)
        let next = try await DeviceLock.acquire(key, command: "tap", wait: .seconds(TestDevices.releaseGrace), root: root)
        next.release()
    }

    @Test("a holder record whose pid has gone, or whose pid started after the lock was taken, is no holder")
    func staleHolder() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.locksDirectoryName, root: root)
        let path = (directory as NSString).appendingPathComponent(key.fileName)
        try "pid=999999\ncommand=tap\nstarted=\(Int(Date().timeIntervalSince1970))\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(DeviceLock.currentHolder(key, root: root, isOffsider: { _ in true }) == nil)

        try "pid=\(getpid())\ncommand=tap\nstarted=1000\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(DeviceLock.currentHolder(key, root: root, isOffsider: { _ in true }) == nil)
        #expect(DeviceLock.currentHolder(key, root: root, isOffsider: { _ in true }, startTime: { _ in Date(timeIntervalSince1970: 999) })?.command == "tap")
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
        try await DeviceLock.acquire(key, command: "swipe", wait: .seconds(TestDevices.releaseGrace), root: root).release()
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
        defer { lock.release() }

        let pid = try spawnSleep()
        defer { reap(pid) }
        #expect(kill(pid, 0) == 0)
        #expect(!process(pid, holds: lock.path))
    }

    @Test("a release frees the device at once while a child still shares the lock's open file")
    func releaseWhileChildSharesLock() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let lock = try await DeviceLock.acquire(key, command: "tap", wait: nil, root: root)
        let shared = try #require(openDescriptor(for: lock.path))

        // As a child mid-posix_spawn on another thread shares it until its exec; this one shares it for its life.
        let pid = try spawnSleep(inheriting: shared)
        defer { reap(pid) }
        #expect(process(pid, holds: lock.path))

        lock.release()
        let again = try await DeviceLock.acquire(key, command: "swipe", wait: nil, root: root)
        again.release()
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
