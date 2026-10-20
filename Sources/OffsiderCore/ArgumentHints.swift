import Foundation

/// Options that do not exist, matched before parsing so the error names the right one instead of "unknown option"; never remapped.
public enum ArgumentHints {
    public struct Hint: Equatable, Sendable {
        public let message: String
        /// A name removed in 0.3.0 or 0.13.0, reported as `legacy_argument`; otherwise a plain usage error.
        public let isLegacy: Bool

        public init(message: String, isLegacy: Bool) {
            self.message = message
            self.isLegacy = isLegacy
        }
    }

    public static let udidMessage = "--udid was renamed to --device in 0.3.0. Run offsider devices to find device IDs."
    public static let listSimulatorsMessage = "list-simulators was renamed to list-devices in 0.3.0."

    /// `device-access` became `devices add`, `remove` and `status` in 0.13.0.
    public static func deviceAccessMessage(_ subcommand: String?) -> String {
        switch subcommand {
        case "allow": return "device-access allow was renamed to devices add in 0.13.0: run offsider devices add."
        case "remove": return "device-access remove was renamed to devices remove in 0.13.0: run offsider devices remove."
        default: return "device-access was renamed to devices status in 0.13.0: run offsider devices status."
        }
    }

    private static let internalBrokerCommand = "hid-broker"

    /// Per command: an option it lacks, and what to use instead.
    static let misnamed: [String: [String: String]] = [
        "wait": partialLabel("wait").merging([
            "--wait-timeout": "wait takes --timeout <seconds>, not --wait-timeout.",
            "--verify-timeout": "wait takes --timeout <seconds>, not --verify-timeout.",
        ]) { $1 },
        "assert": partialLabel("assert").merging([
            "--timeout": "assert checks once and has no --timeout. To wait for the condition, run offsider wait with the same selector and --timeout <seconds>.",
        ]) { $1 },
        "tap": partialLabel("tap").merging([
            "--timeout": "tap has no --timeout: --wait-timeout <seconds> waits for the element to appear, and --verify-timeout <seconds> (with --verify) waits for the tap's effect.",
        ]) { $1 },
        "slider": partialLabel("slider"),
        "describe-ui": [
            "--json": "describe-ui prints JSON by default and has no --json; --format chooses json, ndjson or text.",
        ],
        "turnstile": Dictionary(uniqueKeysWithValues: ["--timeout", "--poll-interval", "--jitter", "--seed"].map { ($0, turnstileReadOnly) }),
        "login": [
            "--turnstile": "login no longer takes --turnstile: it never taps Turnstile, and stops with turnstile_required when a widget is on screen so a person can complete it.",
        ],
    ]

    public static let turnstileReadOnly = "turnstile no longer taps; it reads the widget's state. Hand a checkbox or challenge to a person."

    /// `--label-prefix` and `--label-includes`, guesses at `--label-contains`.
    private static func partialLabel(_ command: String) -> [String: String] {
        let message = "\(command) takes --label-contains <text> for part of a label, in the same case."
        return ["--label-prefix": message, "--label-includes": message]
    }

    /// The hint for `arguments` (without the executable path), or nil to leave them to the parser.
    public static func hint(for arguments: [String]) -> Hint? {
        guard let first = arguments.first, first != internalBrokerCommand else { return nil }
        if first == "list-simulators" {
            return Hint(message: listSimulatorsMessage, isLegacy: true)
        }
        if first == "device-access" {
            return Hint(message: deviceAccessMessage(arguments.dropFirst().first), isLegacy: true)
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
