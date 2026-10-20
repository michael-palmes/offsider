import Darwin
import Foundation

/// This user's other `offsider` processes serving a broker, found by their arguments and the socket they hold: the way a command names a broker
/// that closed its connection before a byte, since macOS no longer tells it the peer's pid or audit token once the peer has closed.
public enum BrokerProcess {
    /// The pids of this user's `offsider` processes, other than this one, whose arguments hold `arguments` in a row (such as `hid-broker --udid <udid>`)
    /// and, with `boundTo`, that hold a Unix socket bound at that path.
    public static func find(
        serving arguments: [String],
        boundTo path: String? = nil,
        pids: () -> [pid_t] = offsiderPids,
        argv: (pid_t) -> [String]? = argv(of:),
        holds: (pid_t, String) -> Bool = holdsSocket(_:boundTo:)
    ) -> [pid_t] {
        pids().filter { pid in
            guard let found = argv(pid), matches(found, serving: arguments) else { return false }
            return path.map { holds(pid, $0) } ?? true
        }
    }

    /// Stops (SIGTERM) each found process whose code is not this build's; one of this build is never stopped, nor one that cannot be identified.
    public static func stopOtherBuilds(
        serving arguments: [String],
        boundTo path: String? = nil,
        requirement: PeerCodeIdentity.Requirement,
        find: ([String], String?) -> [pid_t] = { find(serving: $0, boundTo: $1) },
        verdict: (pid_t, PeerCodeIdentity.Requirement) -> PeerCodeIdentity.Verdict = PeerCodeIdentity.check(pid:requirement:),
        stop: (pid_t) -> Void = { _ = kill($0, SIGTERM) }
    ) -> (stopped: [pid_t], ownBuild: [pid_t]) {
        var stopped: [pid_t] = []
        var ownBuild: [pid_t] = []
        for pid in find(arguments, path) where pid != getpid() {
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

    /// The arguments after `argv[0]` hold `arguments` in a row; a device id compares without case, as `--device` takes it.
    static func matches(_ argv: [String], serving arguments: [String]) -> Bool {
        let rest = Array(argv.dropFirst())
        guard !arguments.isEmpty, rest.count >= arguments.count else { return false }
        return (0...(rest.count - arguments.count)).contains { start in
            zip(rest[start..<(start + arguments.count)], arguments).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
        }
    }

    /// Every live process of this user, other than this one, whose executable is named `offsider`; only those have their arguments read.
    public static func offsiderPids() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
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

    /// The process's raw `KERN_PROCARGS2` buffer; nil for a process that cannot be read.
    public static func procargs(_ pid: pid_t) -> [UInt8]? {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard unsafe sysctlbyname("kern.argmax", &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard unsafe sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(length))
    }

    /// The process's arguments, `argv[0]` first; nil for a process that cannot be read.
    public static func argv(of pid: pid_t) -> [String]? {
        procargs(pid).flatMap(HostSessionParser.argv)
    }

    /// True when `pid` holds a Unix socket bound at `path`, as a broker holds the socket it listens on.
    public static func holdsSocket(_ pid: pid_t, boundTo path: String) -> Bool {
        let wanted = (path as NSString).standardizingPath
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = unsafe proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let bytes = unsafe proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard bytes > 0 else { return false }
        for descriptor in descriptors.prefix(Int(bytes) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard unsafe proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size, info.psi.soi_family == AF_UNIX else { continue }
            let bound = unsafe withUnsafeBytes(of: &info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { raw in
                String(decoding: Array(raw.prefix { $0 != 0 }), as: UTF8.self)
            }
            if !bound.isEmpty, (bound as NSString).standardizingPath == wanted { return true }
        }
        return false
    }
}
