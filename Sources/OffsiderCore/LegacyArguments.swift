import Foundation

/// Names removed in 0.3.0, matched before parsing so users get the new name instead of "unknown option".
public enum LegacyArguments {
    public static let udidMessage = "--udid was renamed to --device in 0.3.0. Run offsider list-devices to find device IDs."
    public static let listSimulatorsMessage = "list-simulators was renamed to list-devices in 0.3.0."

    private static let internalBrokerCommand = "hid-broker"

    /// `arguments` excludes the executable path.
    public static func migrationMessage(for arguments: [String]) -> String? {
        guard let first = arguments.first, first != internalBrokerCommand else { return nil }
        if first == "list-simulators" {
            return listSimulatorsMessage
        }
        for argument in arguments {
            if argument == "--" {
                break
            }
            if argument == "--udid" || argument.hasPrefix("--udid=") {
                return udidMessage
            }
        }
        return nil
    }
}
