import Darwin
import Foundation

/// Why a broker's Unix socket could not be bound or named; each broker words it for its own users.
public enum UnixSocketError: Error, Equatable, Sendable {
    case pathTooLong(String)
    case alreadyServed(String)
    case notOwnedSocket(String)
    case system(operation: String, path: String, code: Int32)
}

/// The per-user Unix stream sockets Offsider's brokers serve: 0600 in a private folder, never replacing another user's file.
public enum UnixSocket {
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw UnixSocketError.pathTooLong(path) }
        unsafe withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Binds `path` 0600 in a private folder (else `PrivateDirectoryError`) and listens; refuses a served path, replaces only this user's stale socket.
    public static func listen(at path: String, uid: uid_t = getuid()) throws -> Int32 {
        // The private folder keeps the socket out of reach until its chmod, without a process-wide umask that would strip other threads' new folders.
        try OffsiderPrivateDirectory.ensurePrivateDirectory((path as NSString).deletingLastPathComponent, uid: uid)
        if answers(path) { throw UnixSocketError.alreadyServed(path) }
        var info = stat()
        if unsafe lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == uid else { throw UnixSocketError.notOwnedSocket(path) }
            unsafe unlink(path)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.system(operation: "socket", path: path, code: errno) }
        var on: Int32 = 1
        unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        do {
            var address = try address(path)
            let bound = unsafe withUnsafePointer(to: &address) {
                unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { throw UnixSocketError.system(operation: "bind", path: path, code: errno) }
            guard unsafe chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw UnixSocketError.system(operation: "chmod", path: path, code: errno) }
            guard Darwin.listen(descriptor, SOMAXCONN) == 0 else { throw UnixSocketError.system(operation: "listen", path: path, code: errno) }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// True when a server accepts a connection at `path`.
    public static func answers(_ path: String) -> Bool {
        guard var address = try? address(path) else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { Darwin.close(probe) }
        let result = unsafe withUnsafePointer(to: &address) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }

    /// The socket file's device and inode, so a broker removes only the socket it bound.
    public static func identity(_ path: String) -> [UInt64]? {
        var info = stat()
        guard unsafe lstat(path, &info) == 0 else { return nil }
        return [UInt64(info.st_dev), UInt64(info.st_ino)]
    }

    /// Unlinks `path` unless another broker has since replaced it.
    public static func remove(_ path: String, ifIdentity expected: [UInt64]?) {
        if let expected, identity(path) == expected { unsafe unlink(path) }
    }

    public static func isSameUser(_ descriptor: Int32, uid: uid_t = getuid()) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        return unsafe getpeereid(descriptor, &peerUID, &peerGID) == 0 && peerUID == uid
    }
}
