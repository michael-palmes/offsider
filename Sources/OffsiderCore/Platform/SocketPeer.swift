import Darwin

/// Reads a connected socket's state without consuming or blocking.
public enum SocketPeer {
    /// True once the peer has closed its end, or the socket has failed.
    public static func closed(_ descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        let count = unsafe recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)
    }
}
