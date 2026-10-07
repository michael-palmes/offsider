import Darwin
import Foundation

/// A run's folder: `run.json`, `manifest.ndjson`, the numbered files, and `.offsider-run.lock` around each counter bump and append.
public struct RunFolder: Equatable, Sendable {
    public static let stateName = "run.json"
    public static let manifestName = "manifest.ndjson"
    public static let lockName = ".offsider-run.lock"

    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// A folder `prepare` made ready, and whether others can write to it (an existing folder keeps its mode).
    public struct Prepared: Equatable, Sendable {
        public let folder: RunFolder
        public let writableByOthers: Bool
    }

    /// Creates the folder 0700 (parents as usual), or takes an existing one this user owns as it is.
    public static func prepare(_ path: String, uid: uid_t = getuid()) throws -> Prepared {
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        var info = stat()
        var created = false
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw PrivateDirectoryError(.system(operation: "lstat", code: errno), path: path) }
            if mkdir(path, S_IRWXU) == 0 {
                created = true
            } else if errno != EEXIST {
                throw PrivateDirectoryError(.system(operation: "mkdir", code: errno), path: path)
            }
            guard lstat(path, &info) == 0 else { throw PrivateDirectoryError(.system(operation: "lstat", code: errno), path: path) }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid else { throw PrivateDirectoryError(.unsafeDirectory, path: path) }
        if created {
            guard chmod(path, S_IRWXU) == 0 else { throw PrivateDirectoryError(.system(operation: "chmod", code: errno), path: path) }
            return Prepared(folder: RunFolder(path: path), writableByOthers: false)
        }
        return Prepared(folder: RunFolder(path: path), writableByOthers: info.st_mode & (S_IWGRP | S_IWOTH) != 0)
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
            var state = try readState() ?? RunState(label: nil, startedAt: now)
            let number = state.next
            state.next += 1
            try writeState(state)
            return number
        }
    }

    /// `NNN-<kind>-<HH.MM.SS>.<ext>` in local time.
    public static func fileName(number: Int, kind: String, at date: Date, extension pathExtension: String, suffix: String = "", timeZone: TimeZone = .current) -> String {
        String(format: "%03d", number) + "-\(kind)-\(RunClock.clock(date, separator: ".", timeZone: timeZone))\(suffix).\(pathExtension)"
    }

    /// Creates a new run file readable only by its owner, as the manifest is, and returns its descriptor; an existing file or a symlink is an error.
    public static func createNew(_ target: String) throws -> Int32 {
        let descriptor = Darwin.open(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PrivateDirectoryError(.system(operation: "open", code: errno), path: target) }
        return descriptor
    }

    /// Writes a new run file through `createNew`.
    public static func writeNew(_ data: Data, toPath target: String) throws {
        let descriptor = try createNew(target)
        defer { Darwin.close(descriptor) }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            guard written > 0 else { throw PrivateDirectoryError(.system(operation: "write", code: errno), path: target) }
            offset += written
        }
    }

    public func append(_ line: RunManifestLine) throws {
        try locked {
            let target = file(Self.manifestName)
            let descriptor = Darwin.open(target, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw PrivateDirectoryError(.system(operation: "open", code: errno), path: target) }
            defer { Darwin.close(descriptor) }
            let data = Data((line.jsonLine() + "\n").utf8)
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard written == data.count else { throw PrivateDirectoryError(.system(operation: "write", code: errno), path: target) }
        }
    }

    /// Every manifest line that parses, oldest first.
    public func manifest() -> [RunManifestLine] {
        guard let data = FileManager.default.contents(atPath: file(Self.manifestName)) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? RunManifestLine(jsonLine: String($0)) }
    }

    /// Numbered files no manifest line names, such as a capture whose command was killed before it could record it.
    public func unrecorded(given lines: [RunManifestLine]) -> [String] {
        let named = Set(lines.flatMap { [$0.file, $0.diff].compactMap { $0 } })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { $0.range(of: #"^\d{3,}-"#, options: .regularExpression) != nil && !named.contains($0) }.sorted()
    }
}
