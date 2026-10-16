import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Untrusted read")
struct UntrustedReadTests {
    private static func folder() throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("untrusted-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("a regular file is read whole")
    func regularFile() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/config.ini"
        try Data("hw.keyboard=yes\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(try UntrustedRead.data(atPath: path) == Data("hw.keyboard=yes\n".utf8))
    }

    @Test("a FIFO with no writer is refused at once instead of blocking")
    func fifo() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/pid_1.ini"
        #expect(mkfifo(path, 0o600) == 0)
        let started = ContinuousClock.now
        #expect(throws: UntrustedRead.Failure.notRegularFile) { try UntrustedRead.data(atPath: path) }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("a symlink is refused, even to a regular file")
    func symlink() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: folder + "/real"))
        try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: folder + "/real")
        try FileManager.default.createSymbolicLink(atPath: folder + "/zero", withDestinationPath: "/dev/zero")
        #expect(throws: UntrustedRead.Failure.symlink) { try UntrustedRead.data(atPath: folder + "/link") }
        #expect(throws: UntrustedRead.Failure.symlink) { try UntrustedRead.data(atPath: folder + "/zero") }
    }

    @Test("a device and a folder are refused")
    func notRegular() throws {
        #expect(throws: UntrustedRead.Failure.notRegularFile) { try UntrustedRead.data(atPath: "/dev/zero") }
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(throws: UntrustedRead.Failure.notRegularFile) { try UntrustedRead.data(atPath: folder) }
    }

    @Test("a file over the cap is refused, unless the caller asks for its start")
    func oversize() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/big"
        try Data(repeating: 0x41, count: 11).write(to: URL(fileURLWithPath: path))
        #expect(throws: UntrustedRead.Failure.tooLarge(maxBytes: 10)) { try UntrustedRead.data(atPath: path, maxBytes: 10) }
        #expect(try UntrustedRead.data(atPath: path, maxBytes: 11).count == 11)
        #expect(try UntrustedRead.data(atPath: path, maxBytes: 4, truncate: true) == Data("AAAA".utf8))
    }

    @Test("a missing file is its own failure, and nil through contents(atPath:)")
    func missing() {
        #expect(throws: UntrustedRead.Failure.missing) { try UntrustedRead.data(atPath: "/nonexistent-\(UUID().uuidString)") }
        #expect(UntrustedRead.contents(atPath: "/nonexistent-\(UUID().uuidString)") == nil)
    }
}
