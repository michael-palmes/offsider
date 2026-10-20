import Darwin

/// `socket` and `accept` with close-on-exec set, so no process Offsider starts, however it is started, holds a connection or listener open.
public enum CloseOnExecSocket {
    /// A new socket, or -1 with `errno` set.
    public static func make(_ domain: Int32, _ type: Int32) -> Int32 {
        closeOnExec(socket(domain, type, 0))
    }

    /// The next connection waiting on `listener`, or -1 with `errno` set.
    public static func accept(_ listener: Int32) -> Int32 {
        closeOnExec(Darwin.accept(listener, nil, nil))
    }

    private static func closeOnExec(_ descriptor: Int32) -> Int32 {
        if descriptor >= 0 { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        return descriptor
    }
}
