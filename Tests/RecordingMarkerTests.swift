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

    @Test("each live recording of a device is named, oldest first, and an ended marker names nobody")
    func pidsOfRecordings() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let key = DeviceLockKey(platform: .ios, id: "SIM-3")
        #expect(RecordingMarker.pids(key, root: root, isRecorder: { _, _ in true }).isEmpty)

        let first = try RecordingMarker.create(key, root: root)
        let second = try RecordingMarker.create(key, root: root)
        #expect(RecordingMarker.pids(key, root: root, isRecorder: { _, _ in true }) == [getpid()])
        first.remove()
        second.remove()
        #expect(RecordingMarker.pids(key, root: root, isRecorder: { _, _ in true }).isEmpty)
    }

    @Test("two recorders' lines both survive in the shared marker, and each is checked before it is named")
    func sharedMarkerKeepsBoth() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let key = DeviceLockKey(platform: .android, id: "emulator-5554")
        let marker = try RecordingMarker.create(key, root: root)
        defer { marker.remove() }
        let other = try #require(FileHandle(forWritingAtPath: marker.path))
        try other.seekToEnd()
        other.write(Data("pid=4242\nstarted=1793434196\npid=4243\nstarted=1793434197\n".utf8))
        try other.close()

        var asked: [(Int32, TimeInterval)] = []
        let named = RecordingMarker.pids(key, root: root) { pid, started in
            asked.append((pid, started.timeIntervalSince1970))
            return pid != 4243
        }
        #expect(named == [getpid(), 4242])
        #expect(asked.count == 3)
        #expect(asked[1].0 == 4242 && asked[1].1 == 1_793_434_196)
    }

    @Test("anyLive sees a live recording on that platform only, so an AVD's name is resolved only when one could match")
    func anyLiveByPlatform() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(!RecordingMarker.anyLive(platform: .android, root: root))
        let marker = try RecordingMarker.create(DeviceLockKey(platform: .android, id: "emulator-5554"), root: root)
        #expect(RecordingMarker.anyLive(platform: .android, root: root))
        #expect(!RecordingMarker.anyLive(platform: .ios, root: root))
        marker.remove()
        #expect(!RecordingMarker.anyLive(platform: .android, root: root))
    }

    @Test("a pid that is not an Offsider process, as a reused one, is never named")
    func foreignPidIsNotNamed() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let key = DeviceLockKey(platform: .ios, id: "SIM-4")
        let marker = try RecordingMarker.create(key, root: root)
        defer { marker.remove() }
        #expect(RecordingMarker.isLive(key, root: root))
        #expect(RecordingMarker.pids(key, root: root).isEmpty)
        #expect(!RecordingMarker.isOffsider(1, started: Date()))
    }
}
