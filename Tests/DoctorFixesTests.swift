import Darwin
import Foundation
import Testing
@testable import Offsider

@Suite("Doctor Fixes Tests")
@MainActor
struct DoctorFixesTests {
    private func makeBrokerDirectory(entries: [String]) throws -> DoctorContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offsider-doctor-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for entry in entries {
            FileManager.default.createFile(atPath: root.appendingPathComponent(entry).path, contents: nil)
        }
        var context = DoctorContext()
        context.brokerRootPath = root.path
        return context
    }

    @Test("A directory holding only stale sockets and locks is removed")
    func removesStaleDirectory() throws {
        let context = try makeBrokerDirectory(entries: ["a-b-v2.sock", "a-b-v2.sock.lock", "a-b-v2.sock.lifetime.lock"])
        defer { try? FileManager.default.removeItem(atPath: context.brokerRootPath) }

        let result = DoctorFixes.removeStaleBrokerDirectory(context)

        #expect(result.outcome == .applied)
        #expect(!FileManager.default.fileExists(atPath: context.brokerRootPath))
        #expect(DoctorFixes.removeStaleBrokerDirectory(context).outcome == .skipped)
    }

    @Test("A directory with a live broker is kept")
    func keepsLiveBroker() throws {
        let context = try makeBrokerDirectory(entries: [])
        defer { try? FileManager.default.removeItem(atPath: context.brokerRootPath) }
        let live = (context.brokerRootPath as NSString).appendingPathComponent("live-v2.sock")
        let stale = (context.brokerRootPath as NSString).appendingPathComponent("stale-v2.sock")
        FileManager.default.createFile(atPath: live, contents: nil)
        FileManager.default.createFile(atPath: stale, contents: nil)
        let lock = try HIDBroker.acquireLifetimeLock(endpoint: live)
        defer {
            flock(lock, LOCK_UN)
            Darwin.close(lock)
        }

        let result = DoctorFixes.removeStaleBrokerDirectory(context)

        #expect(result.outcome == .skipped)
        #expect(FileManager.default.fileExists(atPath: stale))
    }

    @Test("A directory with entries Offsider did not create is kept")
    func keepsUnknownEntries() throws {
        let context = try makeBrokerDirectory(entries: ["a-b-v2.sock", "notes.txt"])
        defer { try? FileManager.default.removeItem(atPath: context.brokerRootPath) }

        let result = DoctorFixes.removeStaleBrokerDirectory(context)

        #expect(result.outcome == .skipped)
        #expect(FileManager.default.fileExists(atPath: context.brokerRootPath))
    }

    @Test("A healthy directory with nothing stale is kept")
    func keepsHealthyDirectory() throws {
        let context = try makeBrokerDirectory(entries: ["a-b-v2.sock.lifetime.lock"])
        defer { try? FileManager.default.removeItem(atPath: context.brokerRootPath) }

        #expect(DoctorFixes.removeStaleBrokerDirectory(context).outcome == .skipped)
        #expect(FileManager.default.fileExists(atPath: context.brokerRootPath))
    }

    @Test("A regular file at the broker path is left in place")
    func keepsFileAtBrokerPath() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("offsider-doctor-fix-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: Data("not ours".utf8), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(atPath: path) }
        var context = DoctorContext()
        context.brokerRootPath = path

        let result = DoctorFixes.removeStaleBrokerDirectory(context)

        #expect(result.outcome == .skipped)
        #expect(FileManager.default.contents(atPath: path) == Data("not ours".utf8))
    }
}
