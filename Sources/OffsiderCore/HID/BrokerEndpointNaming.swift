import Foundation

public enum BrokerEndpointNaming {
    public static let protocolVersion = 2
    public static let socketExtension = "sock"

    public static func rootDirectoryName(uid: UInt32) -> String {
        "offsider-hid-\(uid)"
    }

    /// `developerDirectory` must already be standardised and symlink-resolved.
    public static func endpointFilename(simulatorUDID: String, developerDirectory: String) -> String {
        // Base 36 keeps the socket path inside the 104-byte sun_path limit.
        let identity = String(fnv1a64(developerDirectory), radix: 36)
        let simulatorIdentity = String(fnv1a64(simulatorUDID), radix: 36)
        return "\(simulatorIdentity)-\(identity)-v\(protocolVersion).\(socketExtension)"
    }

    public static func isBrokerOwnedEntry(_ name: String) -> Bool {
        name.hasSuffix(".\(socketExtension)") || name.hasSuffix(".lock")
    }

    public static func fnv1a64(_ string: String) -> UInt64 {
        string.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
