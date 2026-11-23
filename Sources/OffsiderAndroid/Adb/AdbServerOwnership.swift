import Darwin
import Foundation
import OffsiderCore
import Synchronization

/// Whose process answers on the adb server's TCP port: checked on a process's first connection, and again once that server has gone.
enum AdbServerOwnership {
    typealias Probe = @Sendable (_ descriptor: Int32, _ uid: uid_t, _ wait: Duration) -> pid_t?

    struct Key: Hashable {
        let endpoint: LoopbackEndpoint
        let uid: uid_t
    }

    struct Server: Equatable {
        let pid: pid_t
        let started: (seconds: Int, microseconds: Int)?

        static func == (lhs: Server, rhs: Server) -> Bool {
            lhs.pid == rhs.pid && lhs.started?.seconds == rhs.started?.seconds && lhs.started?.microseconds == rhs.started?.microseconds
        }
    }

    private static let verified = Mutex<[Key: Server]>([:])

    /// Tries the server this user's last command found first, which saves a scan of every process; the hint is only an order.
    static let liveProbe: Probe = { descriptor, uid, wait in
        let directory = try? OffsiderPrivateDirectory.ensureSubdirectory(hintDirectory)
        let hint = directory.flatMap { try? OffsiderPrivateDirectory.readOwnedFile(named: hintFile, in: $0, maxBytes: 16) }.flatMap { pid_t(String(decoding: $0, as: UTF8.self)) }
        let pid = LoopbackOwner.acceptingProcess(of: descriptor, uid: uid, wait: wait, preferring: hint)
        if let pid, pid != hint, let directory {
            try? OffsiderPrivateDirectory.writeAtomically(Data(String(pid).utf8), named: hintFile, in: directory)
        }
        return pid
    }
    static let plainProbe: Probe = { descriptor, uid, wait in LoopbackOwner.acceptingProcess(of: descriptor, uid: uid, wait: wait) }
    static let hintDirectory = "adb"
    static let hintFile = "server-pid"

    /// The pid of the process of `uid` that accepted `descriptor`'s connection to `endpoint`, or nil when another user's process holds the port.
    static func verify(_ descriptor: Int32, endpoint: LoopbackEndpoint, uid: uid_t, wait: Duration, probe: Probe) -> pid_t? {
        let key = Key(endpoint: endpoint, uid: uid)
        if let known = verified.withLock({ $0[key] }), known.started != nil, Server(pid: known.pid, started: ProcessStartTime.of(known.pid)) == known {
            return known.pid
        }
        guard let pid = probe(descriptor, uid, wait) else {
            verified.withLock { $0[key] = nil }
            return nil
        }
        verified.withLock { $0[key] = Server(pid: pid, started: ProcessStartTime.of(pid)) }
        return pid
    }

    /// The process this one found serving `endpoint`, once a connection to it has been checked.
    static func server(for endpoint: LoopbackEndpoint, uid: uid_t = getuid()) -> pid_t? {
        verified.withLock { $0[Key(endpoint: endpoint, uid: uid)]?.pid }
    }
}
