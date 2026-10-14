import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Recording marker")
struct RecordingMarkerTests {
    static func root() throws -> String {
        let path = NSTemporaryDirectory() + "offsider-marker-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }

    @Test("the marker reads live, 0600, only while a recording holds it, and goes when the last one ends")
    func lifecycle() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let key = DeviceLockKey(platform: .ios, id: "SIM-1")
        #expect(!RecordingMarker.isLive(key, root: root))

        let first = try RecordingMarker.create(key, root: root)
        let second = try RecordingMarker.create(key, root: root)
        #expect(RecordingMarker.isLive(key, root: root))
        var info = stat()
        #expect(lstat(first.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(first.path.hasSuffix("/locks/ios-SIM-1.recording"))

        first.remove()
        #expect(RecordingMarker.isLive(key, root: root))
        second.remove()
        #expect(!RecordingMarker.isLive(key, root: root))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!RecordingMarker.isLive(DeviceLockKey(platform: .android, id: "emulator-5554"), root: root))
    }

    @Test("a marker its recorder left behind does not read live")
    func leftBehind() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let key = DeviceLockKey(platform: .ios, id: "SIM-2")
        let path = RecordingMarker.path(for: key, root: root)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("pid=1\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(!RecordingMarker.isLive(key, root: root))
    }
}
