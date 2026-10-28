import Darwin
import Foundation

/// Who answers on a loopback TCP port, found from this end of a connection to it rather than from the listener, which another user could share.
public enum LoopbackOwner {
    /// True when a process running as `uid` accepted a connection to 127.0.0.1:`port`; waits up to `wait` for the accept.
    public static func acceptedByUser(port: Int, uid: uid_t = getuid(), wait: Duration = .seconds(1)) -> Bool {
        guard let target = UInt16(exactly: port), let (descriptor, local) = connect(port: target) else { return false }
        defer { Darwin.close(descriptor) }
        let deadline = ContinuousClock.now + wait
        repeat {
            if holdsAcceptedSocket(port: target, peerPort: local, uid: uid) { return true }
            usleep(20_000)
        } while ContinuousClock.now < deadline
        return false
    }

    /// A connected socket to 127.0.0.1:`port` and the local port it got, or nil when nothing answers within a second.
    private static func connect(port: UInt16) -> (Int32, UInt16)? {
        let descriptor = CloseOnExecSocket.make(AF_INET, SOCK_STREAM)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let started = withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        var pending: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard started == 0 || errno == EINPROGRESS, unsafe poll(&ready, 1, 1_000) == 1,
              unsafe getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pending, &length) == 0, pending == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        var bound = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe getsockname(descriptor, $0, &size) }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return (descriptor, UInt16(bigEndian: bound.sin_port))
    }

    /// True when some process of `uid` holds the far end of this connection: a TCP socket on `port` whose peer is 127.0.0.1:`peerPort`.
    private static func holdsAcceptedSocket(port: UInt16, peerPort: UInt16, uid: uid_t) -> Bool {
        let pidStride = MemoryLayout<pid_t>.stride
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
        guard needed > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(needed) / pidStride + 64)
        let bytes = unsafe proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), &pids, Int32(pids.count * pidStride))
        guard bytes > 0 else { return false }
        let loopback = INADDR_LOOPBACK.bigEndian
        let stride = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(Int(bytes) / pidStride) where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
            let listed = unsafe proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
            guard listed > 0 else { continue }
            for descriptor in descriptors.prefix(Int(listed) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
                guard unsafe proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                      info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
                let inet = unsafe info.psi.soi_proto.pri_tcp.tcpsi_ini
                guard UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)) == port,
                      UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_fport)) == peerPort,
                      unsafe inet.insi_faddr.ina_46.i46a_addr4.s_addr == loopback else { continue }
                return true
            }
        }
        return false
    }
}
