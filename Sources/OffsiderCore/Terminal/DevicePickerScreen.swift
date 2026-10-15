import Foundation

/// The pickers a person gets at a terminal when a command names no device: which running simulator or emulator to drive,
/// and which simulator or AVD to boot. Physical devices are never offered, so a phone is only ever named with `--device`.
public enum DevicePickerScreen {
    public static let deviceQuestion = "Which device?"
    public static let bootQuestion = "Which one to boot?"
    public static let noneRunning = "No simulator or emulator running."
    public static let noneToBoot = "No simulator or AVD found."
    public static let running = "running"
    public static let cancelled = "👋 Cancelled, nothing run."
    public static let bootCommand = "offsider boot"

    /// The dim line after a picker no one answered, above the original parse error.
    public static func unanswered(within waited: String, boot: Bool = false) -> String {
        boot ? "Nothing chosen to boot within \(waited); pass its name, such as offsider boot <avd>." : "No device chosen within \(waited); pass --device <id>."
    }

    /// Booted simulators and running emulators only.
    public static func runningDevices(_ rows: [DeviceSummary]) -> [DeviceSummary] {
        rows.filter { [.simulator, .emulator].contains($0.kind) && $0.state == "Booted" }
    }

    /// Every simulator and AVD: running ones first, then AVDs, then simulators on the newest iOS first. A running AVD shows once, as its emulator.
    public static func bootable(_ rows: [DeviceSummary]) -> [DeviceSummary] {
        let virtual = rows.filter { $0.kind != .physical }
        let runningAVDs = Set(virtual.filter { $0.kind == .emulator }.compactMap(\.avd))
        let offered = virtual.filter { $0.kind != .avd || !runningAVDs.contains($0.avd ?? $0.name) }
        let stopped = offered.filter { !isRunning($0) }.enumerated().sorted { first, second in
            let (a, b) = (first.element, second.element)
            if a.platform != b.platform { return a.platform == .android }
            let order = (b.osVersion ?? "").compare(a.osVersion ?? "", options: .numeric)
            return order == .orderedSame ? first.offset < second.offset : order == .orderedAscending
        }.map(\.element)
        return offered.filter(isRunning) + stopped
    }

    public static func isRunning(_ row: DeviceSummary) -> Bool {
        row.kind != .avd && row.state == "Booted"
    }

    /// What `boot` takes for the row: the AVD name, or the simulator's UDID so a shared name is never ambiguous.
    public static func bootName(_ row: DeviceSummary) -> String {
        row.platform == .android ? row.avd ?? row.name : row.id
    }

    /// `📱  iPhone 17 Pro  iOS 27.0`.
    public static func deviceRow(_ row: DeviceSummary) -> MenuRow {
        MenuRow(AllowScreen.mark(row), [PromptScreen.label(row.name), PromptScreen.label(row.osVersion ?? "")])
    }

    /// `🤖  Pixel_9  running`, or the OS version for one that is not.
    public static func bootRow(_ row: DeviceSummary) -> MenuRow {
        MenuRow(AllowScreen.mark(row), [PromptScreen.label(row.platform == .android ? row.avd ?? row.name : row.name), isRunning(row) ? running : PromptScreen.label(row.osVersion ?? "")])
    }

    /// The dim line after a pick: `Using iPhone 17 Pro · add --device <id> to skip this`.
    public static func using(_ row: DeviceSummary, style: TerminalStyle) -> String {
        style.dim("Using \(PromptScreen.label(row.name)) \(style.dot) add --device \(PromptScreen.visible(row.id)) to skip this")
    }
}
