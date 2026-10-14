import Darwin
import Foundation

/// `posix_spawn` failed before the child started, or its log file could not be opened safely.
public struct DetachedProcessError: Error, Equatable, Sendable {
    public let path: String
    public let detail: String

    public init(path: String, detail: String) {
        self.path = path
        self.detail = detail
    }
}

/// `posix_spawn` in a new session, so Ctrl+C on the command never reaches the child, which outlives it.
public struct DetachedProcess: Sendable {
    /// A log over this size is emptied before the next child appends to it.
    public static let maxLogBytes: off_t = 5 << 20

    public init() {}

    /// stdin is /dev/null; stdout and stderr append to `logPath`, opened here so a link or another user's file is refused;
    /// the child sees exactly `environment` and inherits no other descriptor.
    public func launch(executable: URL, arguments: [String], environment: [String: String], logPath: String) throws -> Int32 {
        let log = try Self.openLog(logPath)
        defer { Darwin.close(log) }

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, log, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw DetachedProcessError(path: executable.path, detail: String(cString: strerror(status)))
        }
        return pid
    }

    /// Opens `path` to append, creating it 0600; refuses a link, a non-regular file, another user's file, or one with other hard links, and empties one over 5 MB.
    public static func openLog(_ path: String, uid: uid_t = getuid(), maxBytes: off_t = maxLogBytes) throws -> Int32 {
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let detail = errno == ELOOP ? "the log path is a symbolic link" : "the log could not be opened: \(String(cString: strerror(errno)))"
            throw DetachedProcessError(path: path, detail: detail)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw DetachedProcessError(path: path, detail: "the log could not be checked: \(detail)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid, info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw DetachedProcessError(path: path, detail: "the log is not a private file this user owns")
        }
        if info.st_size > maxBytes { _ = ftruncate(descriptor, 0) }
        // The child writes blocking; O_NONBLOCK was only for the open.
        _ = fcntl(descriptor, F_SETFL, O_APPEND)
        return descriptor
    }

    /// The exit status once the launched process has exited (128 plus the signal when killed), else nil.
    public func exitStatus(of pid: Int32) -> Int32? {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return nil }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
