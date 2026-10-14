import Darwin
import Foundation

/// `~/.config/offsider`, found from the password database so neither `HOME` nor `XDG_CONFIG_HOME` can move it.
public struct UserConfigDirectory: Sendable {
    public static let configName = ".config"
    public static let offsiderName = "offsider"

    public let home: String
    public let uid: uid_t

    public init(home: String, uid: uid_t = getuid()) {
        self.home = home
        self.uid = uid
    }

    /// The account's home from `getpwuid_r`; nil when the password database has no entry.
    public static func home(uid: uid_t = getuid()) -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var size = sysconf(_SC_GETPW_R_SIZE_MAX)
        if size <= 0 { size = 16_384 }
        var buffer = [CChar](repeating: 0, count: size)
        guard getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0, result != nil, let directory = entry.pw_dir else { return nil }
        let path = String(cString: directory)
        return path.isEmpty ? nil : path
    }

    /// The live directory for this user, or nil when the account has no home.
    public static func live() -> UserConfigDirectory? {
        home().map { UserConfigDirectory(home: $0) }
    }

    /// `~/.config/offsider` when it exists and is safe; nil when either folder is missing. Creates nothing.
    public func existing() throws -> String? {
        guard let config = try configFolder(create: false) else { return nil }
        let path = (config as NSString).appendingPathComponent(Self.offsiderName)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw PrivateDirectoryError(.system(operation: "lstat", code: errno), path: path)
        }
        guard Self.isSafeFolder(info, uid: uid) else { throw PrivateDirectoryError(.unsafeDirectory, path: path) }
        return path
    }

    /// `~/.config/offsider`, created 0700 (and `~/.config` 0700 when missing); an existing `offsider` folder is tightened to 0700.
    public func ensure() throws -> String {
        guard let config = try configFolder(create: true) else {
            throw PrivateDirectoryError(.unsafeDirectory, path: (home as NSString).appendingPathComponent(Self.configName))
        }
        let path = (config as NSString).appendingPathComponent(Self.offsiderName)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid else { throw PrivateDirectoryError(.unsafeDirectory, path: path) }
            guard chmod(path, S_IRWXU) == 0 else { throw PrivateDirectoryError(.system(operation: "chmod", code: errno), path: path) }
        }
        try OffsiderPrivateDirectory.ensurePrivateDirectory(path, uid: uid)
        return path
    }

    /// `~/.config`, resolved once when it is a symlink; the folder (or the link's target) must be this user's and writable by no one else.
    private func configFolder(create: Bool) throws -> String? {
        let path = (home as NSString).appendingPathComponent(Self.configName)
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw PrivateDirectoryError(.system(operation: "lstat", code: errno), path: path) }
            guard create else { return nil }
            guard mkdir(path, S_IRWXU) == 0 || errno == EEXIST else { throw PrivateDirectoryError(.system(operation: "mkdir", code: errno), path: path) }
            guard lstat(path, &info) == 0 else { throw PrivateDirectoryError(.system(operation: "lstat", code: errno), path: path) }
        }
        var folder = path
        if (info.st_mode & S_IFMT) == S_IFLNK {
            guard info.st_uid == uid, let target = Self.resolveOnce(path) else { throw PrivateDirectoryError(.unsafeDirectory, path: path) }
            guard lstat(target, &info) == 0 else {
                if errno == ENOENT, !create { return nil }
                throw PrivateDirectoryError(.unsafeDirectory, path: path)
            }
            folder = target
        }
        guard Self.isSafeFolder(info, uid: uid) else { throw PrivateDirectoryError(.unsafeDirectory, path: folder) }
        return folder
    }

    /// A real directory owned by `uid` that no group or other user can write.
    static func isSafeFolder(_ info: stat, uid: uid_t) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == uid && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    /// The link's target, made absolute against the link's folder; nil when it cannot be read.
    private static func resolveOnce(_ link: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(link, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        let target = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return target.hasPrefix("/") ? target : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
    }
}
