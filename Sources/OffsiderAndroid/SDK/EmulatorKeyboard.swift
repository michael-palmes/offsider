import Foundation

/// Whether a running AVD has a hardware keyboard: without one, its key devices declare few keys, so gRPC keys and text never arrive.
enum EmulatorKeyboard {
    /// The emulator writes the hardware it booted with here, in the AVD's directory, on every boot.
    static let fileName = "hardware-qemu.ini"

    /// `hw.keyboard` as the running emulator booted with it; nil when the file or the value is missing.
    static func present(in discovery: EmulatorDiscovery, files: any FileSystemProbe) -> Bool? {
        guard let directory = discovery.avdDirectory,
              let data = files.contents(atPath: (directory as NSString).appendingPathComponent(fileName)) else {
            return nil
        }
        return flag(IniFile.parse(String(decoding: data, as: UTF8.self))["hw.keyboard"])
    }

    /// `true` or `false` as `hardware-qemu.ini` writes them, or `yes` or `no` as `config.ini` does; nil for anything else.
    private static func flag(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: return nil
        }
    }
}
