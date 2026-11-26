import Foundation

/// `OFFSIDER_UNATTENDED`: nobody is at the Mac, so every person gate refuses at once with the step instead of asking and waiting.
/// It only tightens, so an agent may set it; a value it does not know counts as on.
public enum UnattendedMode {
    public static let variable = "OFFSIDER_UNATTENDED"
    static let offValues: Set<String> = ["0", "false", "no", "off"]

    public static func isOn(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return false }
        return !offValues.contains(value)
    }

    public static func isOn(environment: [String: String]) -> Bool {
        isOn(environment[variable])
    }

    /// The clause every unattended refusal opens its reason with.
    public static let because = "\(variable) is on"
}
