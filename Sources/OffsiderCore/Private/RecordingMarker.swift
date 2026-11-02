import Darwin
import Foundation

/// `locks/<platform>-<id>.recording`: present and `flock`ed while `record-video` records the device, so `login` can refuse to type a password into the video.
public final class RecordingMarker: @unchecked Sendable {
    /// Commands that may type a secret; `record-video` refuses while one holds the device lock.
    public static let refusedHolderCommands: Set<String> = ["login", "wake", "type"]

    public let path: String
    private var descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit { remove() }

    public static func path(for key: DeviceLockKey, root: String = OffsiderPrivateDirectory.root) -> String {
        let name = (key.fileName as NSString).deletingPathExtension + ".recording"
        return ((root as NSString).appendingPathComponent(OffsiderPrivateDirectory.locksDirectoryName) as NSString).appendingPathComponent(name)
    }

    /// Creates the marker (0600) and holds its lock until `remove` or exit; another live recording of the device shares the same marker.
    public static func create(_ key: DeviceLockKey, root: String = OffsiderPrivateDirectory.root) throws -> RecordingMarker {
        _ = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.locksDirectoryName, root: root)
        let path = path(for: key, root: root)
        for _ in 0..<5 {
            let descriptor = try OffsiderPrivateDirectory.openPrivateFile(path)
            while flock(descriptor, LOCK_SH | LOCK_NB) != 0 {
                guard errno == EINTR else {
                    Darwin.close(descriptor)
                    throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: path)
                }
            }
            // A recorder finishing at this moment may have unlinked the file this descriptor opened.
            var opened = stat()
            var current = stat()
            guard unsafe fstat(descriptor, &opened) == 0, unsafe lstat(path, &current) == 0, opened.st_ino == current.st_ino, opened.st_dev == current.st_dev else {
                Darwin.close(descriptor)
                continue
            }
            // Appended, as two recordings of one device share the file and each must stay findable.
            let line = Array("pid=\(getpid())\nstarted=\(Int(Date().timeIntervalSince1970))\n".utf8)
            _ = fcntl(descriptor, F_SETFL, O_APPEND)
            _ = unsafe write(descriptor, line, line.count)
            return RecordingMarker(path: path, descriptor: descriptor)
        }
        throw PrivateDirectoryError(.system(operation: "open", code: EAGAIN), path: path)
    }

    /// True while some `record-video` holds the marker for `key`; a marker its recorder left behind reads false.
    public static func isLive(_ key: DeviceLockKey, root: String = OffsiderPrivateDirectory.root) -> Bool {
        let descriptor = unsafe Darwin.open(path(for: key, root: root), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            return errno == EWOULDBLOCK
        }
        _ = flock(descriptor, LOCK_UN)
        return false
    }

    /// True while any recording of a `platform` device runs.
    public static func anyLive(platform: DevicePlatform, root: String = OffsiderPrivateDirectory.root) -> Bool {
        let folder = (root as NSString).appendingPathComponent(OffsiderPrivateDirectory.locksDirectoryName)
        let prefix = "\(platform.rawValue)-"
        let suffix = ".recording"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.contains { name in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
            return isLive(DeviceLockKey(platform: platform, id: String(name.dropFirst(prefix.count).dropLast(suffix.count))), root: root)
        }
    }

    /// The pids of `key`'s running recordings, oldest first; one that has ended or whose pid was reused is left out.
    public static func pids(
        _ key: DeviceLockKey, root: String = OffsiderPrivateDirectory.root,
        isRecorder: (Int32, _ started: Date) -> Bool = { isOffsider($0, started: $1) }
    ) -> [Int32] {
        guard isLive(key, root: root), let data = try? UntrustedRead.data(atPath: path(for: key, root: root), maxBytes: maximumMarkerBytes) else { return [] }
        var found: [Int32] = []
        var pid: Int32?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("pid=") {
                pid = Int32(line.dropFirst("pid=".count))
            } else if line.hasPrefix("started="), let current = pid, let seconds = TimeInterval(line.dropFirst("started=".count)) {
                if !found.contains(current), isRecorder(current, Date(timeIntervalSince1970: seconds)) { found.append(current) }
                pid = nil
            }
        }
        return found
    }

    private static let maximumMarkerBytes = 1 << 16

    /// A running `offsider` that started by the time the marker names; a reused pid starts later.
    public static func isOffsider(_ pid: Int32, started: Date) -> Bool {
        guard let path = ProcessPath.of(pid: pid), (path as NSString).lastPathComponent == "offsider",
              let began = ProcessStartTime.date(of: pid) else { return false }
        return began.timeIntervalSince(started) <= 1
    }

    /// Releases this recording's hold; the file goes once no other recording holds it.
    public func remove() {
        guard descriptor >= 0 else { return }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { unsafe unlink(path) }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}
