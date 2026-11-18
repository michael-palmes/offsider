import Foundation

/// Full-disk encryption's "To start Android, enter your PIN": boot reads complete, yet `/data` stays a small temporary disk until a person enters it.
public enum BootPINPrompt {
    static let key = "boot_pin"

    /// One line: `ro.crypto.state`, `ro.crypto.type`, `vold.decrypt` and `vold.encrypt_progress`, each empty when unset.
    public static let script = "echo \(key)=$(getprop ro.crypto.state),$(getprop ro.crypto.type),$(getprop vold.decrypt),$(getprop vold.encrypt_progress)"

    /// AOSP cryptfs: `vold.decrypt` is `trigger_restart_min_framework` while the prompt (or, with `vold.encrypt_progress` set, encryption progress) shows; `ro.crypto.type` is `block`, unset before Android 7.
    public static func isShowing(_ output: String) -> Bool {
        let prefix = key + "="
        guard let line = output.split(whereSeparator: \.isNewline).lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let fields = line.dropFirst(prefix.count).split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 4 else { return false }
        return fields[0] == "encrypted" && fields[1] != "file" && fields[2] == "trigger_restart_min_framework" && fields[3].isEmpty
    }

    /// Lines without the `script` line, so the positional lines read beside it keep their places.
    public static func withoutLine(_ lines: [String]) -> [String] {
        lines.filter { !$0.hasPrefix(key + "=") }
    }

    public static func ask(name: String) -> String {
        PersonAsk.filled("Can you enter the PIN on \(PersonAsk.devicePlaceholder)?", name: name, id: nil)
    }

    /// `doctor`'s fix: a person enters the PIN on the device, or an emulator is swapped for an AVD without one.
    public static func hint(name: String, isPhysical: Bool, audience: ErrorAudience = .current) -> String {
        let other = isPhysical ? "" : " Or boot an AVD that has no boot PIN."
        guard audience == .agent else { return "Enter the PIN on its screen; Offsider never types it.\(other)" }
        return "Ask the user: \(ask(name: name)) Offsider never types it.\(other)"
    }

    /// For `boot` and `lease set` on an emulator at the prompt.
    public static func notice(name: String) -> Notice {
        let shown = TerminalText.line(name, cap: PersonAsk.maximumNameLength, keepsTab: false)
        return .warning(
            "\(shown) is waiting for its boot PIN; enter it on its screen before installing apps",
            agent: "\(shown) is waiting for its boot PIN, so apps cannot be installed. Ask the user: \(ask(name: name)) Offsider never types it. Or boot an AVD that has no boot PIN."
        )
    }
}
