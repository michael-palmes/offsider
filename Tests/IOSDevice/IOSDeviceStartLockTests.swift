import Darwin
import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

struct StartLockBusy: Error {}

@Suite("iOS device start lock")
struct StartLockTests {
    /// Rewrites the owner line in place, as a lock left by an exited command would read; the file and any `flock` on it stay.
    static func claimForExitedProcess(_ path: String) throws {
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("\(exited.processIdentifier) 12345\n".utf8))
        try handle.close()
    }

    static func path() throws -> String {
        let directory = try IOSDevicePaths.device(IOSDeviceFixtures.phone, root: RunnerTestPaths.temporaryRoot())
        return (directory as NSString).appendingPathComponent("start.lock")
    }

    @Test("a lock dropped without release is freed when it closes, and the file stays for the next holder")
    func freedOnClose() async throws {
        let path = try Self.path()
        var held: IOSDeviceStartLock? = try await IOSDeviceStartLock.acquire(path, timeout: 0, poll: .milliseconds(10)) { StartLockBusy() }
        #expect(held != nil)
        await #expect(throws: StartLockBusy.self) { _ = try await IOSDeviceStartLock.acquire(path, timeout: 0.1, poll: .milliseconds(10)) { StartLockBusy() } }
        held = nil
        let next = try await IOSDeviceStartLock.acquire(path, timeout: TestDevices.releaseGrace, poll: .milliseconds(10)) { StartLockBusy() }
        #expect(FileManager.default.fileExists(atPath: path))
        next.release()
    }

    @Test("concurrent waiters on a lock left by an exited command hold it one at a time")
    func oneHolderAtATime() async throws {
        let path = try Self.path()
        try Data().write(to: URL(fileURLWithPath: path))
        chmod(path, S_IRUSR | S_IWUSR)
        try Self.claimForExitedProcess(path)
        let tracker = OverlapTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let lock = try await IOSDeviceStartLock.acquire(path, timeout: 30, poll: .milliseconds(10)) { StartLockBusy() }
                    tracker.enter()
                    try await Task.sleep(for: .milliseconds(100))
                    tracker.leave()
                    lock.release()
                }
            }
            try await group.waitForAll()
        }
        #expect(tracker.entries == 4 && tracker.peak == 1)
    }
}
