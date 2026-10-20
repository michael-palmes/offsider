import Foundation

/// How `devices` orders rows and the one next step it suggests to a person.
public enum DeviceListOrder {
    /// Booted rows first, then booting ones, within each platform; platforms and every other row keep their order.
    public static func sorted(_ devices: [DeviceSummary]) -> [DeviceSummary] {
        var platforms: [DevicePlatform] = []
        for device in devices where !platforms.contains(device.platform) { platforms.append(device.platform) }
        return platforms.flatMap { platform in
            devices.enumerated().filter { $0.element.platform == platform }
                .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
                .map(\.element)
        }
    }

    /// Rows that are booted or still booting.
    public static func running(_ devices: [DeviceSummary]) -> [DeviceSummary] {
        devices.filter { rank($0) < 2 }
    }

    /// One line for a person: the one booted simulator or emulator to use, or one to boot; never a physical device.
    public static func nextStep(_ devices: [DeviceSummary], currentDefault: String?) -> String? {
        nextCommand(devices, currentDefault: currentDefault).map { "Next: " + $0 }
    }

    /// The command `nextStep` names, for a person only: it may `export`, which an agent's next shell would not keep.
    public static func nextCommand(_ devices: [DeviceSummary], currentDefault: String?) -> String? {
        let virtual = devices.filter { $0.kind != .physical }
        let booted = virtual.filter { $0.state == "Booted" }
        if booted.count == 1 {
            let id = booted[0].id
            return currentDefault == id ? "offsider doctor --device \(id)" : "export OFFSIDER_DEVICE=\(id)"
        }
        guard booted.isEmpty, let first = virtual.first(where: { rank($0) == 2 && ($0.kind == .avd || $0.kind == .simulator) }) else { return nil }
        return "offsider boot \(first.kind == .avd ? (first.avd ?? first.name) : first.id)"
    }

    private static func rank(_ device: DeviceSummary) -> Int {
        switch device.state {
        case "Booted": return 0
        case "Booting": return 1
        default: return 2
        }
    }
}
