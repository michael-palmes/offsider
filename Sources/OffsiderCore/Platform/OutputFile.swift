import Darwin
import Foundation

/// A file an output path could not take, with the reason in words.
public struct OutputFileError: LocalizedError, Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Writes captures to user-chosen paths without following links, replacing another user's file, or leaving a half-written file in place.
public enum OutputFile {
    /// The only kinds of existing file `--output` may replace.
    public static let replaceableExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "mp4", "mov", "m4v"]
    static let maxComponentLength = 64
    /// Highest " N" suffix tried before giving up on a free name.
    static let maxSuffix = 999

    /// A device name made safe for a file name: separators and control characters become "-", bidi and zero-width marks go, leading dots go, at most 64 characters.
    public static func sanitisedComponent(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let value = scalar.value
            if isInvisible(value) { continue }
            if value == 0x2F || value == 0x3A || value < 0x20 || (0x7F...0x9F).contains(value) {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        var text = String(scalars)
        while text.hasPrefix(".") { text.removeFirst() }
        text = String(text.prefix(maxComponentLength))
        return text.isEmpty ? "device" : text
    }

    private static func isInvisible(_ value: UInt32) -> Bool {
        value == 0x061C || (0x200B...0x200F).contains(value) || (0x202A...0x202E).contains(value) || value == 0x2060
            || (0x2066...0x2069).contains(value) || value == 0xFEFF
    }

    /// `name`, or "name 2", "name 3" and so on before the extension.
    static func candidate(_ path: String, attempt: Int) -> String {
        guard attempt > 1 else { return path }
        let ext = (path as NSString).pathExtension
        let stem = ext.isEmpty ? path : (path as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(ext)"
    }

    /// Writes a new file at `path` (0600, never over anything), or at the first free "<name> N" beside it; returns the path written.
    public static func writeNew(_ data: Data, at path: String) throws -> String {
        for attempt in 1...maxSuffix {
            let target = candidate(path, attempt: attempt)
            let descriptor: Int32
            do {
                descriptor = try RunFolder.createNew(target)
            } catch let error as PrivateDirectoryError {
                if case .system(_, let code) = error.kind, code == EEXIST { continue }
                throw OutputFileError(path: target, "Offsider could not create \(target): \(error.localizedDescription)")
            }
            do {
                try write(data, to: descriptor, path: target)
                Darwin.close(descriptor)
            } catch {
                Darwin.close(descriptor)
                unlink(target)
                throw error
            }
            return target
        }
        throw OutputFileError(path: path, "Offsider found no free file name beside \(path).")
    }

    /// Replaces `path` whole through a sibling temporary file and `rename`, or creates it; an existing entry must be a regular file this user owns with an allowed extension.
    public static func replace(_ data: Data, at path: String, allowedExtensions: Set<String> = replaceableExtensions, uid: uid_t = getuid()) throws {
        try checkReplaceable(path, allowedExtensions: allowedExtensions, uid: uid)
        let temporary = try temporarySibling(of: path)
        let descriptor: Int32
        do {
            descriptor = try RunFolder.createNew(temporary)
        } catch {
            throw OutputFileError(path: path, "Offsider could not write beside \(path): \(error.localizedDescription)")
        }
        do {
            try write(data, to: descriptor, path: temporary)
            guard fsync(descriptor) == 0 else { throw OutputFileError(path: path, "Offsider could not flush \(path): \(String(cString: strerror(errno))).") }
            Darwin.close(descriptor)
            guard rename(temporary, path) == 0 else { throw OutputFileError(path: path, "Offsider could not replace \(path): \(String(cString: strerror(errno))).") }
        } catch {
            Darwin.close(descriptor)
            unlink(temporary)
            throw error
        }
    }

    /// Nothing at `path`, or a regular file this user owns whose extension is allowed.
    public static func checkReplaceable(_ path: String, allowedExtensions: Set<String> = replaceableExtensions, uid: uid_t = getuid()) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw OutputFileError(path: path, "Offsider could not check \(path): \(String(cString: strerror(errno))).")
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: throw OutputFileError(path: path, "\(path) is a directory. Name a file, or point to a different location.")
        case S_IFLNK: throw OutputFileError(path: path, "\(path) is a symbolic link, so Offsider will not write through it. Name the file itself.")
        default: throw OutputFileError(path: path, "\(path) is not a regular file, so Offsider will not replace it.")
        }
        guard info.st_uid == uid else {
            throw OutputFileError(path: path, "\(path) belongs to another user, so Offsider will not replace it.")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw OutputFileError(path: path, "\(path) already exists and is not an image or video file, so Offsider will not replace it. Choose a new name.")
        }
    }

    private static func temporarySibling(of path: String) throws -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = ".\((path as NSString).lastPathComponent).offsider-\(UUID().uuidString.prefix(8))"
        return directory.isEmpty ? name : (directory as NSString).appendingPathComponent(name)
    }

    private static func write(_ data: Data, to descriptor: Int32, path: String) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw OutputFileError(path: path, "Offsider could not write \(path): \(String(cString: strerror(errno))).") }
            offset += written
        }
    }

    /// A private (0700) directory beside `target` for a writer that names its own file, such as AVAssetWriter; `commit` moves the result out.
    public static func stagingDirectory(for target: String) throws -> String {
        let directory = (target as NSString).deletingLastPathComponent
        var template = Array(((directory.isEmpty ? "." : directory) as NSString).appendingPathComponent(".offsider-staging-XXXXXX").utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw OutputFileError(path: target, "Offsider could not create a staging folder beside \(target): \(String(cString: strerror(errno))).")
        }
        let path = String(cString: made)
        chmod(path, S_IRWXU)
        return path
    }

    /// Moves a staged file to `target`: replacing only as `replace` allows when `replacing`, else at the first free "<name> N"; the staging folder is removed. Returns the final path.
    public static func commit(
        _ staged: String, to target: String, replacing: Bool, allowedExtensions: Set<String> = replaceableExtensions, uid: uid_t = getuid()
    ) throws -> String {
        let staging = (staged as NSString).deletingLastPathComponent
        defer { discardStaging(staging) }
        var info = stat()
        guard lstat(staged, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid else {
            throw OutputFileError(path: target, "The staged file for \(target) is missing or not a regular file.")
        }
        chmod(staged, S_IRUSR | S_IWUSR)
        if replacing {
            try checkReplaceable(target, allowedExtensions: allowedExtensions, uid: uid)
            guard rename(staged, target) == 0 else { throw OutputFileError(path: target, "Offsider could not move the recording to \(target): \(String(cString: strerror(errno))).") }
            return target
        }
        for attempt in 1...maxSuffix {
            let candidate = candidate(target, attempt: attempt)
            if renamex_np(staged, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { throw OutputFileError(path: candidate, "Offsider could not move the recording to \(candidate): \(String(cString: strerror(errno))).") }
        }
        throw OutputFileError(path: target, "Offsider found no free file name beside \(target).")
    }

    /// Removes a staging folder and what is left in it, without following links.
    public static func discardStaging(_ staging: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: staging) else { return }
        for name in names { unlink((staging as NSString).appendingPathComponent(name)) }
        rmdir(staging)
    }
}
