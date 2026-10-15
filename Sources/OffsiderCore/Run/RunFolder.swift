import Darwin
import Foundation

/// A run's folder: `run.json`, `manifest.ndjson`, the numbered files, and `.offsider-run.lock` around each counter bump and append.
public struct RunFolder: Equatable, Sendable {
    public static let stateName = "run.json"
    public static let manifestName = "manifest.ndjson"
    public static let lockName = ".offsider-run.lock"
    /// Written into a folder `prepare` creates, so git never picks up a run's captures.
    public static let gitignoreName = ".gitignore"

    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// A folder `prepare` made ready, and whether others can write to it (an existing folder keeps its mode).
    public struct Prepared: Equatable, Sendable {
        public let folder: RunFolder
        public let writableByOthers: Bool
    }

    /// Creates the folder 0700 (parents as usual) with a `.gitignore` of `*`, or takes an existing one this user owns as it is.
    public static func prepare(_ path: String, uid: uid_t = getuid()) throws -> Prepared {
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        var info = stat()
        var created = false
        if unsafe lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw PrivateDirectoryError(.system(operation: "lstat", code: errno), path: path) }
            if unsafe mkdir(path, S_IRWXU) == 0 {
                created = true
            } else if errno != EEXIST {
                throw PrivateDirectoryError(.system(operation: "mkdir", code: errno), path: path)
            }
            guard unsafe lstat(path, &info) == 0 else { throw PrivateDirectoryError(.system(operation: "lstat", code: errno), path: path) }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid else { throw PrivateDirectoryError(.unsafeDirectory, path: path) }
        if created {
            guard unsafe chmod(path, S_IRWXU) == 0 else { throw PrivateDirectoryError(.system(operation: "chmod", code: errno), path: path) }
            let folder = RunFolder(path: path)
            try writeNew(Data("*\n".utf8), toPath: folder.file(gitignoreName))
            return Prepared(folder: folder, writableByOthers: false)
        }
        return Prepared(folder: RunFolder(path: path), writableByOthers: info.st_mode & (S_IWGRP | S_IWOTH) != 0)
    }

    /// Why a recorded run folder cannot be trusted.
    public struct RecordedFolderError: LocalizedError, Equatable, Sendable {
        public let path: String
        public let detail: String
        public var errorDescription: String? { "\(path) \(detail)" }
    }

    /// The folder a run record names, only while it is an absolute, standardised path to a real directory this user owns that no one else
    /// can write, holding a private `run.json` for the same run (same label, started no later than the record).
    public static func validateRecorded(_ record: RunRecord, uid: uid_t = getuid()) throws -> RunFolder {
        let path = record.dir
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw RecordedFolderError(path: path, detail: "is not an absolute, standardised path")
        }
        var info = stat()
        guard unsafe lstat(path, &info) == 0 else {
            throw RecordedFolderError(path: path, detail: unsafe "cannot be read: \(String(cString: strerror(errno)))")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw RecordedFolderError(path: path, detail: "is not a directory (a link or a file stands there)") }
        guard info.st_uid == uid else { throw RecordedFolderError(path: path, detail: "belongs to another user") }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw RecordedFolderError(path: path, detail: "can be written by other users") }
        let data: Data?
        do {
            data = try OffsiderPrivateDirectory.readOwnedFile(named: stateName, in: path, maxBytes: RunState.maximumBytes, uid: uid)
        } catch {
            throw RecordedFolderError(path: path, detail: "has a \(stateName) that is not a private file")
        }
        guard let data, let state = try? RunCoding.decoder.decode(RunState.self, from: data) else {
            throw RecordedFolderError(path: path, detail: "has no readable \(stateName)")
        }
        guard state.label == record.label, state.startedAt <= record.startedAt else {
            throw RecordedFolderError(path: path, detail: "holds another run's \(stateName)")
        }
        return RunFolder(path: path)
    }

    public func file(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }

    /// Holds the folder's `flock` for `body`; the kernel drops it if the process dies.
    public func locked<T>(_ body: () throws -> T) throws -> T {
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(file(Self.lockName))
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: file(Self.lockName)) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    public func readState() throws -> RunState? {
        guard let data = try OffsiderPrivateDirectory.readOwnedFile(named: Self.stateName, in: path, maxBytes: RunState.maximumBytes) else { return nil }
        return try RunCoding.decoder.decode(RunState.self, from: data)
    }

    public func writeState(_ state: RunState) throws {
        try OffsiderPrivateDirectory.writeAtomically(try RunCoding.encoder.encode(state), named: Self.stateName, in: path)
    }

    /// Takes the next file number under the lock, so concurrent commands never share one.
    public func reserveNumber(now: Date) throws -> Int {
        try locked {
            var state = try readState() ?? RunState(label: nil, startedAt: now, masks: .defaults)
            let number = state.next
            state.next += 1
            try writeState(state)
            return number
        }
    }

    /// `NNN-<kind>-<HH.MM.SS>.<ext>` in local time.
    public static func fileName(number: Int, kind: String, at date: Date, extension pathExtension: String, suffix: String = "", timeZone: TimeZone = .current) -> String {
        unsafe String(format: "%03d", number) + "-\(kind)-\(RunClock.clock(date, separator: ".", timeZone: timeZone))\(suffix).\(pathExtension)"
    }

    /// Creates a new run file readable only by its owner, as the manifest is, and returns its descriptor; an existing file or a symlink is an error.
    public static func createNew(_ target: String) throws -> Int32 {
        let descriptor = unsafe Darwin.open(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PrivateDirectoryError(.system(operation: "open", code: errno), path: target) }
        return descriptor
    }

    /// Writes a new run file through `createNew`.
    public static func writeNew(_ data: Data, toPath target: String) throws {
        let descriptor = try createNew(target)
        defer { Darwin.close(descriptor) }
        var offset = 0
        while offset < data.count {
            let written = unsafe data.withUnsafeBytes { unsafe Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            guard written > 0 else { throw PrivateDirectoryError(.system(operation: "write", code: errno), path: target) }
            offset += written
        }
    }

    public func append(_ line: RunManifestLine) throws {
        try locked {
            let target = file(Self.manifestName)
            let descriptor = unsafe Darwin.open(target, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw PrivateDirectoryError(.system(operation: "open", code: errno), path: target) }
            defer { Darwin.close(descriptor) }
            let data = Data((line.jsonLine() + "\n").utf8)
            let written = unsafe data.withUnsafeBytes { unsafe Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard written == data.count else { throw PrivateDirectoryError(.system(operation: "write", code: errno), path: target) }
        }
    }

    /// Every manifest line that parses, oldest first.
    public func manifest() -> [RunManifestLine] {
        guard let data = UntrustedRead.contents(atPath: file(Self.manifestName), maxBytes: 16 << 20, truncate: true) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? RunManifestLine(jsonLine: String($0)) }
    }

    /// Numbered files no manifest line names, such as a capture whose command was killed before it could record it.
    public func unrecorded(given lines: [RunManifestLine]) -> [String] {
        let named = Set(lines.flatMap { [$0.file, $0.diff].compactMap { $0 } })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { $0.range(of: #"^\d{3,}-"#, options: .regularExpression) != nil && !named.contains($0) }.sorted()
    }
}
