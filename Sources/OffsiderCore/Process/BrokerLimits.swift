import Darwin

/// Resource limits a long-lived broker sets on itself before it opens a device handle.
public enum BrokerLimits {
    /// Descriptors a broker may hold open; its clients, the device's sockets and the frameworks' own fit well inside.
    public static let maxOpenFiles: rlim_t = 256

    /// No core dump at all, so a crash never writes frames or tokens to disk; the open-file soft limit lowered, never raised, to 256.
    public static func limits(currentFiles: rlimit) -> (core: rlimit, files: rlimit) {
        var files = currentFiles
        files.rlim_cur = min(maxOpenFiles, currentFiles.rlim_cur, currentFiles.rlim_max)
        return (rlimit(rlim_cur: 0, rlim_max: 0), files)
    }

    /// Applies `limits` to this process; false when either could not be set.
    @discardableResult
    public static func apply() -> Bool {
        let coreSet = disableCoreDumps()
        var current = rlimit()
        guard unsafe getrlimit(RLIMIT_NOFILE, &current) == 0 else { return false }
        var files = limits(currentFiles: current).files
        return unsafe setrlimit(RLIMIT_NOFILE, &files) == 0 && coreSet
    }

    /// Every command starts here: one may hold a password, a code or a frame, so none may ever write a core file, nor any child it starts.
    @discardableResult
    public static func disableCoreDumps() -> Bool {
        var none = rlimit(rlim_cur: 0, rlim_max: 0)
        return unsafe setrlimit(RLIMIT_CORE, &none) == 0
    }
}
