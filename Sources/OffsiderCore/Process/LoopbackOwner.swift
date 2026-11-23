import Darwin
import Foundation

/// Who answers on a loopback TCP port, found from this end of a connection to it rather than from the listener, which another user could share.
public enum LoopbackOwner {
    /// True when a process running as `uid` accepted a connection to 127.0.0.1:`port`; waits up to `wait` for the accept.
    public static func acceptedByUser(port: Int, uid: uid_t = getuid(), wait: Duration = .seconds(1)) -> Bool {
        guard let target = UInt16(exactly: port), let (descriptor, local) = connect(port: target) else { return false }
        defer { Darwin.close(descriptor) }
        return waitForAccept(port: target, peerPort: local, ipv6: false, uid: uid, wait: wait) != nil
    }

    /// The process of `uid` that accepted `descriptor`'s loopback TCP connection within `wait`, `preferring` tried first as a hint.
    public static func acceptingProcess(of descriptor: Int32, uid: uid_t = getuid(), wait: Duration = .seconds(1), preferring: pid_t? = nil) -> pid_t? {
        var local = sockaddr_storage()
        var remote = sockaddr_storage()
        var localSize = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var remoteSize = localSize
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe getsockname(descriptor, $0, &localSize) }
        }
        let peered = withUnsafeMutablePointer(to: &remote) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe getpeername(descriptor, $0, &remoteSize) }
        }
        guard named == 0, peered == 0, local.ss_family == remote.ss_family else { return nil }
        switch Int32(remote.ss_family) {
        case AF_INET:
            let mine = withUnsafeBytes(of: &local) { unsafe $0.load(as: sockaddr_in.self) }
            let theirs = withUnsafeBytes(of: &remote) { unsafe $0.load(as: sockaddr_in.self) }
            guard theirs.sin_addr.s_addr == INADDR_LOOPBACK.bigEndian else { return nil }
            return waitForAccept(port: UInt16(bigEndian: theirs.sin_port), peerPort: UInt16(bigEndian: mine.sin_port), ipv6: false, uid: uid, wait: wait, preferring: preferring)
        case AF_INET6:
            let mine = withUnsafeBytes(of: &local) { unsafe $0.load(as: sockaddr_in6.self) }
            let theirs = withUnsafeBytes(of: &remote) { unsafe $0.load(as: sockaddr_in6.self) }
            guard isIPv6Loopback(theirs.sin6_addr) else { return nil }
            return waitForAccept(port: UInt16(bigEndian: theirs.sin6_port), peerPort: UInt16(bigEndian: mine.sin6_port), ipv6: true, uid: uid, wait: wait, preferring: preferring)
        default:
            return nil
        }
    }

    /// The executable `pid` runs, or nil when it has gone or belongs to another user.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = unsafe proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func waitForAccept(port: UInt16, peerPort: UInt16, ipv6: Bool, uid: uid_t, wait: Duration, preferring: pid_t? = nil) -> pid_t? {
        let deadline = ContinuousClock.now + wait
        repeat {
            if let preferring, holdsAcceptedSocket(preferring, port: port, peerPort: peerPort, ipv6: ipv6, uid: uid) { return preferring }
            if let pid = acceptingPID(port: port, peerPort: peerPort, ipv6: ipv6, uid: uid) { return pid }
            usleep(20_000)
        } while ContinuousClock.now < deadline
        return nil
    }

    private static func isIPv6Loopback(_ address: in6_addr) -> Bool {
        withUnsafeBytes(of: address) { bytes in unsafe Array(bytes) } == [UInt8](repeating: 0, count: 15) + [1]
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

    /// The process of `uid` holding the far end of this connection: a TCP socket on `port` whose peer is loopback:`peerPort`.
    private static func acceptingPID(port: UInt16, peerPort: UInt16, ipv6: Bool, uid: uid_t) -> pid_t? {
        let pidStride = MemoryLayout<pid_t>.stride
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) / pidStride + 64)
        let bytes = unsafe proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), &pids, Int32(pids.count * pidStride))
        guard bytes > 0 else { return nil }
        return pids.prefix(Int(bytes) / pidStride).first { $0 > 0 && holdsSocket($0, port: port, peerPort: peerPort, ipv6: ipv6) }
    }

    /// `holdsSocket`, for a pid that must also run as `uid`.
    private static func holdsAcceptedSocket(_ pid: pid_t, port: UInt16, peerPort: UInt16, ipv6: Bool, uid: uid_t) -> Bool {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard pid > 0, unsafe proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == uid else { return false }
        return holdsSocket(pid, port: port, peerPort: peerPort, ipv6: ipv6)
    }

    private static func holdsSocket(_ pid: pid_t, port: UInt16, peerPort: UInt16, ipv6: Bool) -> Bool {
        let loopback = INADDR_LOOPBACK.bigEndian
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let listed = unsafe proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard listed > 0 else { return false }
        for descriptor in descriptors.prefix(Int(listed) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard unsafe proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let inet = unsafe info.psi.soi_proto.pri_tcp.tcpsi_ini
            guard UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)) == port,
                  UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_fport)) == peerPort else { continue }
            let fromLoopback = ipv6
                ? unsafe isIPv6Loopback(inet.insi_faddr.ina_6)
                : unsafe inet.insi_faddr.ina_46.i46a_addr4.s_addr == loopback
            if fromLoopback { return true }
        }
        return false
    }
}
