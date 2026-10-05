import Foundation

/// Checks `boot --emulator-arg` tokens: nothing that opens a listener, sends metrics or overrides what Offsider sets.
public enum EmulatorArguments {
    /// A trailing `*` matches any flag with that prefix.
    public static let refusedFlags: [(flag: String, reason: String)] = [
        ("-port", "it starts the emulator without a gRPC endpoint, so Offsider falls back to adb"),
        ("-ports", "it starts the emulator without a gRPC endpoint, so Offsider falls back to adb"),
        ("-grpc*", "a bare -grpc binds every interface with no auth; Offsider's own launch serves gRPC on loopback with auth"),
        ("-gnss-grpc-port", "it opens another network listener"),
        ("-idle-grpc-timeout", "it stops the emulator when Offsider's gRPC is idle"),
        ("-metrics*", "Offsider always passes -no-metrics"),
        ("-qemu", "everything after it goes straight to QEMU"),
        ("-fuchsia", "everything after it goes straight to QEMU"),
        ("-shell-serial", "it attaches a root shell to a character device"),
        ("-shell", "it attaches a root shell to this terminal"),
        ("-modem-simulator-port", "it opens another network listener"),
        ("-wifi-server-port", "it opens another network listener"),
        ("-wifi-client-port", "it connects to another emulator over the network"),
        ("-wifi-socket", "it opens a network socket"),
        ("-wifi-tap*", "it bridges the emulator onto a host network interface"),
        ("-net-socket", "it opens a network socket"),
        ("-net-tap*", "it bridges the emulator onto a host network interface"),
        ("-vmnet-*", "it bridges the emulator onto a host network"),
        ("-shared-net-id", "it joins a network shared with other emulators"),
        ("-packet-streamer-endpoint", "it streams packets to a network endpoint"),
        ("-report-console", "it reports the console port to a socket"),
        ("-turncfg", "it relays WebRTC through a TURN server"),
        ("-avd", "Offsider names the AVD from boot's argument"),
        ("-no-window", "use --headless"),
        ("-memory", "use --memory"),
        ("-no-snapshot-load", "use --no-snapshot-load"),
    ]

    /// `--grpc=8554` and `-GRPC` both normalise to `-grpc`; a value such as `host` is left alone.
    static func normalised(_ token: String) -> String? {
        guard token.hasPrefix("-") else { return nil }
        let name = token.drop { $0 == "-" }.prefix { $0 != "=" }.lowercased()
        return name.isEmpty ? nil : "-" + name
    }

    /// The refusal message for the first refused token, or nil when every token may be passed.
    public static func refusal(in tokens: [String]) -> String? {
        for token in tokens {
            guard let flag = normalised(token) else { continue }
            let match = refusedFlags.first { entry in
                entry.flag.hasSuffix("*") ? flag.hasPrefix(String(entry.flag.dropLast())) : flag == entry.flag
            }
            if let match {
                return "--emulator-arg \(token) is refused: \(match.reason)."
            }
        }
        return nil
    }
}
