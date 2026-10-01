import Darwin
import Foundation

/// Starts the emulator so it outlives the command; a protocol so tests never start one.
protocol EmulatorLaunching: Sendable {
    func launch(executable: URL, arguments: [String], environment: [String: String], logPath: String) throws -> Int32
    /// The exit status once the launched process has exited (128 plus the signal when killed), else nil.
    func exitStatus(of pid: Int32) -> Int32?
}

/// `posix_spawn` in a new session, so Ctrl+C on `offsider boot` never reaches the emulator.
struct DetachedProcess: EmulatorLaunching {
    /// stdin is /dev/null; stdout and stderr append to `logPath`; `ADB_MDNS=0` is added to the environment.
    func launch(executable: URL, arguments: [String], environment: [String: String], logPath: String) throws -> Int32 {
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        var merged = environment
        merged["ADB_MDNS"] = "0"
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw AndroidError.emulatorLaunchFailed(path: executable.path, detail: String(cString: strerror(status)))
        }
        return pid
    }

    func exitStatus(of pid: Int32) -> Int32? {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return nil }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
