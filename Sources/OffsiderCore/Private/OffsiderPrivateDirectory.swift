import Darwin
import Foundation

/// Why a private directory or file was refused.
public struct PrivateDirectoryError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Not a real directory owned by the user with no group or other bits.
        case unsafeDirectory
        /// Not a regular file owned by the user with no group or other bits.
        case unsafeFile
        /// A system call failed with this errno.
        case system(operation: String, code: Int32)
    }

    public let kind: Kind
    public let path: String

    public init(_ kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }
}

extension PrivateDirectoryError: OffsiderFailure {
    public var reason: FailureReason { .privateDirectoryUnsafe }

    public var failureMessage: String {
        switch kind {
        case .unsafeDirectory:
            return "\(path) is not a private directory owned by this user."
        case .unsafeFile:
            return "\(path) is not a private file owned by this user."
        case .system(let operation, let code):
            return "\(operation) \(path) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Offsider's per-user directory, `<user temp>/offsider-<uid>/`, mode 0700; it holds `locks/`, the tree cache in `trees/` and evidence run records in `runs/`.
public enum OffsiderPrivateDirectory {
    public static let locksDirectoryName = "locks"
    public static let treesDirectoryName = "trees"
    public static let leasesDirectoryName = "leases"
    public static let orientationDirectoryName = "orientation"
    public static let runsDirectoryName = "runs"

    public static func rootName(uid: uid_t) -> String {
        "offsider-\(uid)"
    }

    /// The per-user temp directory from `confstr`, which ignores `TMPDIR`, resolved for symlinks.
    public static func darwinUserTempDirectory() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return resolved(path)
    }

    /// The root in use for this process, chosen once.
    public static var root: String { cachedRoot }

    private static let cachedRoot = resolveRoot(
        uid: getuid(),
        userTemp: darwinUserTempDirectory(),
        fallbackTemp: NSTemporaryDirectory()
    )

    /// Prefers the `confstr` root so agents with different `TMPDIR` values share it; falls back to `TMPDIR` when it cannot be made private.
    public static func resolveRoot(uid: uid_t, userTemp: String?, fallbackTemp: String) -> String {
        if let userTemp {
            let candidate = (userTemp as NSString).appendingPathComponent(rootName(uid: uid))
            if (try? ensurePrivateDirectory(candidate, uid: uid)) != nil {
                return candidate
            }
        }
        return (resolved(fallbackTemp) as NSString).appendingPathComponent(rootName(uid: uid))
    }

    /// `root/name`, both created 0700 and checked; returns the subdirectory's path.
    public static func ensureSubdirectory(_ name: String, root: String = OffsiderPrivateDirectory.root, uid: uid_t = getuid()) throws -> String {
        try ensurePrivateDirectory(root, uid: uid)
        let path = (root as NSString).appendingPathComponent(name)
        try ensurePrivateDirectory(path, uid: uid)
        return path
    }

    /// Accepts or creates a real directory owned by `uid` with no group or other bits, re-checked with `lstat`.
    public static func ensurePrivateDirectory(_ path: String, uid: uid_t) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard isPrivateDirectory(info, uid: uid) else { throw PrivateDirectoryError(.unsafeDirectory, path: path) }
            return
        }
        guard errno == ENOENT else { throw systemError("lstat", path) }
        guard mkdir(path, S_IRWXU) == 0 || errno == EEXIST else { throw systemError("mkdir", path) }
        guard lstat(path, &info) == 0 else { throw systemError("lstat", path) }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid else {
            throw PrivateDirectoryError(.unsafeDirectory, path: path)
        }
        guard chmod(path, S_IRWXU) == 0 else { throw systemError("chmod", path) }
        guard lstat(path, &info) == 0 else { throw systemError("lstat", path) }
        guard isPrivateDirectory(info, uid: uid) else { throw PrivateDirectoryError(.unsafeDirectory, path: path) }
    }

    /// Opens or creates a 0600 regular file owned by `uid`, never through a symlink and never inherited by a child.
    public static func openPrivateFile(_ path: String, uid: uid_t = getuid()) throws -> Int32 {
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw systemError("open", path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = systemError("fstat", path)
            Darwin.close(descriptor)
            throw error
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid, info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            Darwin.close(descriptor)
            throw PrivateDirectoryError(.unsafeFile, path: path)
        }
        return descriptor
    }

    /// Writes a fresh 0600 file beside `name` (never through a symlink), then renames it over `name`, so a reader sees the old or the new file whole.
    public static func writeAtomically(_ data: Data, named name: String, in directory: String, uid: uid_t = getuid()) throws {
        let target = (directory as NSString).appendingPathComponent(name)
        let temporary = (directory as NSString).appendingPathComponent(".\(name).\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let descriptor = Darwin.open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw systemError("open", temporary) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid,
              info.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            Darwin.close(descriptor)
            unlink(temporary)
            throw PrivateDirectoryError(.unsafeFile, path: temporary)
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        let failure = written ? nil : systemError("write", temporary)
        Darwin.close(descriptor)
        if let failure {
            unlink(temporary)
            throw failure
        }
        guard Darwin.rename(temporary, target) == 0 else {
            let error = systemError("rename", target)
            unlink(temporary)
            throw error
        }
    }

    /// The file's bytes, or nil when it does not exist; refuses a symlink, a file another user owns, one with group or other bits, or one over `maxBytes`.
    public static func readOwnedFile(named name: String, in directory: String, maxBytes: Int, uid: uid_t = getuid()) throws -> Data? {
        let path = (directory as NSString).appendingPathComponent(name)
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw PrivateDirectoryError(.unsafeFile, path: path) }
            throw systemError("open", path)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError("fstat", path) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid, info.st_mode & (S_IRWXG | S_IRWXO) == 0,
              info.st_size <= off_t(maxBytes) else {
            throw PrivateDirectoryError(.unsafeFile, path: path)
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let read = Darwin.read(descriptor, base + offset, buffer.count - offset)
                if read < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if read == 0 { break }
                offset += read
            }
            return offset
        }
        guard count >= 0 else { throw systemError("read", path) }
        return data.prefix(count)
    }

    public static func removeFile(named name: String, in directory: String) {
        unlink((directory as NSString).appendingPathComponent(name))
    }

    private static func isPrivateDirectory(_ info: stat, uid: uid_t) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == uid && info.st_mode & (S_IRWXG | S_IRWXO) == 0
    }

    private static func systemError(_ operation: String, _ path: String) -> PrivateDirectoryError {
        PrivateDirectoryError(.system(operation: operation, code: errno), path: path)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
    }
}

extension PrivateDirectoryError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { failureMessage }
    public var description: String { failureMessage }
}
