import Foundation
import OffsiderCore

/// The appearance a device reports through `devicectl device info appearance`.
public struct IOSDeviceAppearance: Equatable, Sendable {
    public var appearance: Appearance
    public var contentSize: ContentSizeCategory

    public init(appearance: Appearance, contentSize: ContentSizeCategory) {
        self.appearance = appearance
        self.contentSize = contentSize
    }
}

/// devicectl argument lists and reply parsers for appearance, text size and orientation.
enum IOSDeviceSettings {
    static func readAppearance(udid: String) -> [String] {
        ["device", "info", "appearance", "--device", udid, "--timeout", "20", "--json-output", "-", "-q"]
    }

    static func readDisplays(udid: String) -> [String] {
        ["device", "info", "displays", "--device", udid, "--timeout", "20", "--json-output", "-", "-q"]
    }

    static func setAppearance(_ appearance: Appearance, udid: String) -> [String] {
        ["device", "settings", "appearance", "--device", udid, "--mode", appearance.rawValue, "--timeout", "20", "-q"]
    }

    /// The accessibility sizes need Larger Accessibility Sizes on; a smaller size leaves that switch as it is.
    static func setContentSize(_ category: ContentSizeCategory, udid: String) -> [String] {
        var arguments = ["device", "settings", "appearance", "--device", udid, "--text-size", category.rawValue]
        if category.rawValue.hasPrefix("accessibility-") {
            arguments += ["--larger-accessibility-sizes", "on"]
        }
        return arguments + ["--timeout", "20", "-q"]
    }

    static func setOrientation(_ orientation: DeviceOrientation, udid: String) -> [String] {
        ["device", "orientation", "set", "--device", udid, devicectlName(orientation), "--timeout", "20", "-q"]
    }

    static func devicectlName(_ orientation: DeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .portraitUpsideDown: return "portraitUpsideDown"
        }
    }

    enum ParseError: Error, Equatable {
        case malformed
        case unknownStyle(String)
        case unknownTextSize(String)

        var detail: String {
            switch self {
            case .malformed: return "it sent no appearance"
            case .unknownStyle(let style): return "it reported the style '\(style)', which is neither light nor dark"
            case .unknownTextSize(let size): return "it reported the text size '\(size)', which is not a known size"
            }
        }
    }

    static func parseAppearance(_ data: Data) throws -> IOSDeviceAppearance {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let style = result["userInterfaceStyle"] as? String,
              let textSize = result["textSize"] as? String else {
            throw ParseError.malformed
        }
        guard let appearance = Appearance(rawValue: style.lowercased()) else {
            throw ParseError.unknownStyle(style)
        }
        guard let category = contentSize(named: textSize) else {
            throw ParseError.unknownTextSize(textSize)
        }
        return IOSDeviceAppearance(appearance: appearance, contentSize: category)
    }

    /// devicectl reports a display name such as `Medium` or `Accessibility Extra Large`; its short forms and camel case are accepted too.
    static func contentSize(named name: String) -> ContentSizeCategory? {
        var words = ""
        var previous: Character?
        for character in name.trimmingCharacters(in: .whitespaces) {
            if character.isUppercase, previous?.isLowercase == true {
                words.append("-")
            }
            words.append(character == " " || character == "_" ? "-" : Character(character.lowercased()))
            previous = character
        }
        if let category = ContentSizeCategory(rawValue: words) { return category }
        return shortNames[words]
    }

    static let shortNames: [String: ContentSizeCategory] = [
        "xs": .extraSmall, "s": .small, "m": .medium, "l": .large, "xl": .extraLarge, "xxl": .extraExtraLarge, "xxxl": .extraExtraExtraLarge,
        "am": .accessibilityMedium, "al": .accessibilityLarge, "axl": .accessibilityExtraLarge,
        "axxl": .accessibilityExtraExtraLarge, "axxxl": .accessibilityExtraExtraExtraLarge,
    ]

    /// The primary display's clockwise turn from portrait (native plus the UI's turn), else `currentDeviceOrientation`; face up or down is unknown.
    static func parseOrientation(displaysJSON data: Data) -> DeviceOrientation? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else { return nil }
        let displays = result["displays"] as? [[String: Any]] ?? []
        if let display = displays.first(where: { ($0["primary"] as? Bool) == true }) ?? displays.first,
           let current = DevicectlDisplays.degrees(display["currentOrientation"] as? String) {
            let native = DevicectlDisplays.degrees(display["nativeOrientation"] as? String) ?? 0
            return DeviceOrientation(rotationDegrees: DevicectlDisplays.anticlockwise((native + current) % 360))
        }
        guard let device = (result["orientation"] as? [String: Any])?["currentDeviceOrientation"] as? String else { return nil }
        return DeviceOrientation.allCases.first { devicectlName($0) == device }
    }
}
