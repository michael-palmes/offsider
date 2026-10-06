import Foundation

/// Checks `boot --emulator-arg` tokens against an allow-list: flags that shape the device or its rendering, never its network, metrics or Offsider's own options.
public enum EmulatorArguments {
    /// An allowed flag; `value` describes the one value it takes, or is nil when it takes none.
    public struct Flag: Sendable {
        public let name: String
        public let value: String?
        let accepts: @Sendable (String) -> Bool

        static func bare(_ name: String) -> Flag {
            Flag(name: name, value: nil) { _ in false }
        }

        static func oneOf(_ name: String, _ values: [String]) -> Flag {
            Flag(name: name, value: values.joined(separator: "|")) { values.contains($0) }
        }

        static func integer(_ name: String, _ range: ClosedRange<Int>) -> Flag {
            Flag(name: name, value: "\(range.lowerBound) to \(range.upperBound)") { text in
                text.allSatisfy(\.isASCII) && Int(text).map(range.contains) == true
            }
        }
    }

    /// Each entry is justified against `emulator -help`; anything that opens a listener, connects out, reads a host path or sends metrics stays off it.
    public static let allowed: [Flag] = [
        .oneOf("-accel", ["auto", "off", "on"]),
        Flag(name: "-camera-back", value: "emulated|none|webcamN") { camera($0) },
        Flag(name: "-camera-front", value: "emulated|none|webcamN") { camera($0) },
        .integer("-cores", 1...16),
        .oneOf("-feature", ["Vulkan", "-Vulkan", "GLESDynamicVersion", "-GLESDynamicVersion"]),
        .oneOf("-gpu", ["auto", "host", "software", "lavapipe", "swiftshader", "swangle"]),
        .bare("-no-audio"),
        .bare("-no-boot-anim"),
        .bare("-no-cache"),
        .bare("-no-snapshot"),
        .bare("-no-snapshot-save"),
        .bare("-noskin"),
        .integer("-partition-size", 512...65536),
        .bare("-read-only"),
        Flag(name: "-skin", value: "WIDTHxHEIGHT|name") { skin($0) },
        .bare("-verbose"),
        .bare("-wipe-data"),
    ]

    /// Flags Offsider sets itself, with the option to use instead.
    static let ownedFlags: [String: String] = [
        "-avd": "boot takes the AVD name as its argument",
        "-no-window": "use --headless",
        "-memory": "use --memory",
        "-no-snapshot-load": "use --no-snapshot-load",
        "-no-metrics": "Offsider always passes it",
    ]

    static func camera(_ value: String) -> Bool {
        if value == "emulated" || value == "none" { return true }
        guard value.hasPrefix("webcam") else { return false }
        let number = value.dropFirst("webcam".count)
        return (1...2).contains(number.count) && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A size such as `1080x2400`, or a skin folder's name with no path in it.
    static func skin(_ value: String) -> Bool {
        value.range(of: #"^([0-9]{2,5}x[0-9]{2,5}|[A-Za-z0-9][A-Za-z0-9_-]{0,63})$"#, options: .regularExpression) != nil
    }

    /// `--memory=4096` and `-MEMORY` both normalise to `-memory`, to point an owned flag at Offsider's option.
    static func normalised(_ token: String) -> String? {
        guard token.hasPrefix("-") else { return nil }
        let name = token.drop { $0 == "-" }.prefix { $0 != "=" }.lowercased()
        return name.isEmpty ? nil : "-" + name
    }

    /// The allowed flags with their values, as a refusal lists them.
    static var allowedList: String {
        sentence(allowed.map { flag in flag.value.map { "\(flag.name) <\($0)>" } ?? flag.name })
    }

    /// The allowed flags' names, as `boot --help` lists them.
    public static var allowedNames: String {
        sentence(allowed.map(\.name))
    }

    private static func sentence(_ items: [String]) -> String {
        items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// The refusal message for the first token that is not an allowed flag or its value, or nil when every token may be passed.
    public static func refusal(in tokens: [String]) -> String? {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard let flag = allowed.first(where: { $0.name == token }) else {
                return "--emulator-arg \(token) is refused: \(reason(forUnlisted: token))."
            }
            index += 1
            guard let value = flag.value else { continue }
            guard index < tokens.count else {
                return "--emulator-arg \(token) is refused: it needs a value (\(value)) in the next --emulator-arg."
            }
            guard flag.accepts(tokens[index]) else {
                return "--emulator-arg \(token) \(tokens[index]) is refused: \(token) takes \(value)."
            }
            index += 1
        }
        return nil
    }

    static func reason(forUnlisted token: String) -> String {
        if token.hasPrefix("@") {
            return "an @ token makes the emulator start another AVD; boot takes the AVD name as its argument"
        }
        if let flag = normalised(token), let owned = ownedFlags[flag] {
            return owned
        }
        let allowedText = "boot passes only \(allowedList), each value in its own --emulator-arg"
        return token.hasPrefix("-") ? allowedText : "it is not the value of an allowed flag; \(allowedText)"
    }
}
