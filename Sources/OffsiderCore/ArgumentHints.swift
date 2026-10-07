import Foundation

/// Options that do not exist, matched before parsing so the error names the right one instead of "unknown option"; never remapped.
public enum ArgumentHints {
    public struct Hint: Equatable, Sendable {
        public let message: String
        /// A name removed in 0.3.0, reported as `legacy_argument`; otherwise a plain usage error.
        public let isLegacy: Bool

        public init(message: String, isLegacy: Bool) {
            self.message = message
            self.isLegacy = isLegacy
        }
    }

    public static let udidMessage = "--udid was renamed to --device in 0.3.0. Run offsider list-devices to find device IDs."
    public static let listSimulatorsMessage = "list-simulators was renamed to list-devices in 0.3.0."

    private static let internalBrokerCommand = "hid-broker"

    /// Per command: an option it lacks, and what to use instead.
    static let misnamed: [String: [String: String]] = [
        "wait": [
            "--wait-timeout": "wait takes --timeout <seconds>, not --wait-timeout.",
            "--verify-timeout": "wait takes --timeout <seconds>, not --verify-timeout.",
        ],
        "assert": [
            "--timeout": "assert checks once and has no --timeout. To wait for the condition, run offsider wait with the same selector and --timeout <seconds>.",
        ],
        "tap": [
            "--timeout": "tap has no --timeout: --wait-timeout <seconds> waits for the element to appear, and --verify-timeout <seconds> (with --verify) waits for the tap's effect.",
        ],
    ]

    /// The hint for `arguments` (without the executable path), or nil to leave them to the parser.
    public static func hint(for arguments: [String]) -> Hint? {
        guard let first = arguments.first, first != internalBrokerCommand else { return nil }
        if first == "list-simulators" {
            return Hint(message: listSimulatorsMessage, isLegacy: true)
        }
        let options = arguments.prefix { $0 != "--" }
        if options.contains(where: { matches($0, "--udid") }) {
            return Hint(message: udidMessage, isLegacy: true)
        }
        guard let table = misnamed[first] else { return nil }
        for option in options.dropFirst() {
            if let message = table.first(where: { matches(option, $0.key) })?.value {
                return Hint(message: message, isLegacy: false)
            }
        }
        return nil
    }

    private static func matches(_ argument: String, _ option: String) -> Bool {
        argument == option || argument.hasPrefix(option + "=")
    }
}
