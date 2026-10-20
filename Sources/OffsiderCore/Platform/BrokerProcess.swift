import Darwin
import Foundation

/// This user's other `offsider` processes serving a broker, found by their arguments: the way a command names a broker that closed its
/// connection before a byte, since macOS no longer tells it the peer's pid or audit token once the peer has closed.
public enum BrokerProcess {
    /// The pids of this user's `offsider` processes, other than this one, whose arguments end with `arguments` (such as `hid-broker --udid <udid>`).
    public static func find(
        serving arguments: [String],
        pids: () -> [pid_t] = offsiderPids,
        argv: (pid_t) -> [String]? = argv(of:)
    ) -> [pid_t] {
        pids().filter { pid in
            guard let found = argv(pid) else { return false }
            return matches(found, serving: arguments)
        }
    }

    /// Stops (SIGTERM) each process serving `arguments` whose code is not this build's; one of this build is never stopped, nor one that cannot be identified.
    public static func stopOtherBuilds(
        serving arguments: [String],
        requirement: PeerCodeIdentity.Requirement,
        find: ([String]) -> [pid_t] = { find(serving: $0) },
        verdict: (pid_t, PeerCodeIdentity.Requirement) -> PeerCodeIdentity.Verdict = PeerCodeIdentity.check(pid:requirement:),
        stop: (pid_t) -> Void = { _ = kill($0, SIGTERM) }
    ) -> (stopped: [pid_t], ownBuild: [pid_t]) {
        var stopped: [pid_t] = []
        var ownBuild: [pid_t] = []
        for pid in find(arguments) where pid != getpid() {
            let checked = verdict(pid, requirement)
            guard checked.identified else { continue }
            if checked.accepted {
                ownBuild.append(pid)
            } else {
                stop(pid)
                stopped.append(pid)
            }
        }
        return (stopped, ownBuild)
    }

    /// The arguments after `argv[0]` end with `arguments`; a device id compares without case, as `--device` takes it.
    static func matches(_ argv: [String], serving arguments: [String]) -> Bool {
        guard !arguments.isEmpty, argv.count > arguments.count else { return false }
        return zip(argv.suffix(arguments.count), arguments).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    /// Every live process of this user, other than this one, whose executable is named `offsider`; only those have their arguments read.
    public static func offsiderPids() -> [pid_t] {
        let capacity = unsafe proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = unsafe proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let me = getpid()
        let uid = getuid()
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0, pid != me, DeviceLock.isOffsiderProcess(pid) else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == uid
        }
    }

    /// The process's arguments from `KERN_PROCARGS2`, `argv[0]` first; nil for a process that cannot be read.
    public static func argv(of pid: pid_t) -> [String]? {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard unsafe sysctlbyname("kern.argmax", &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard unsafe sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        return HostSessionParser.argv(Array(buffer.prefix(length)))
    }
}
