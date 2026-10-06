import Darwin
import Foundation

/// A process by pid and kernel start time, so a reused pid is never mistaken for the process that had it.
public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    /// Microseconds since 1970, from the kernel's process start time.
    public var startTime: UInt64
    /// The kernel's short command name, such as `node` or `zsh`.
    public var name: String

    public init(pid: Int32, startTime: UInt64, name: String) {
        self.pid = pid
        self.startTime = startTime
        self.name = name
    }
}

/// Looks up a live process and its parent; a test scripts its own table.
public struct ProcessTable: Sendable {
    public var lookup: @Sendable (Int32) -> (identity: ProcessIdentity, parent: Int32)?

    public init(lookup: @escaping @Sendable (Int32) -> (identity: ProcessIdentity, parent: Int32)?) {
        self.lookup = lookup
    }

    /// `sysctl KERN_PROC_PID`; nil once the process has exited or is a zombie.
    public static let live = ProcessTable { pid in
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let start = info.kp_proc.p_starttime
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let identity = ProcessIdentity(pid: pid, startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec), name: name)
        return (identity, info.kp_eproc.e_ppid)
    }

    /// True when the process is still the one `identity` names.
    public func isAlive(_ identity: ProcessIdentity) -> Bool {
        lookup(identity.pid)?.identity.startTime == identity.startTime
    }
}

/// Walks a process's parents to find the agent or terminal session that owns an evidence run.
public enum ProcessAncestry {
    /// Shells and wrappers between a session and the commands it runs; the owner is the first ancestor not among them.
    public static let wrappers: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "timeout", "nohup", "nice", "time", "xargs", "caffeinate", "sandbox-exec",
    ]
    public static let maximumDepth = 64

    /// `pid` and then each parent, up to 64 steps, stopping before pid 1 (launchd).
    public static func ancestors(of pid: Int32, in table: ProcessTable) -> [ProcessIdentity] {
        var chain: [ProcessIdentity] = []
        var current = pid
        while chain.count < maximumDepth, current > 1, let entry = table.lookup(current) {
            chain.append(entry.identity)
            guard entry.parent != current else { break }
            current = entry.parent
        }
        return chain
    }

    /// The first ancestor from `parent` (the caller's parent) that is not a shell or wrapper, such as Claude Code's `node` or a terminal's `login`.
    public static func owner(from parent: Int32, in table: ProcessTable) -> ProcessIdentity? {
        ancestors(of: parent, in: table).first { !wrappers.contains($0.name) }
    }
}
