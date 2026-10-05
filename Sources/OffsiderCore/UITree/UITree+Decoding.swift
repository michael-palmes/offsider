import Foundation

public struct UITreeDecodingError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

extension UITree {
    /// Reads a describe-ui v2 JSON envelope; a node without `native` gets empty attributes for its platform.
    public init(jsonData: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw UITreeDecodingError(description: "describe-ui JSON must be an object")
        }
        guard (object["version"] as? NSNumber)?.intValue == Self.schemaVersion else {
            throw UITreeDecodingError(description: "describe-ui JSON is not version \(Self.schemaVersion)")
        }
        guard let platformName = object["platform"] as? String, let platform = DevicePlatform(rawValue: platformName) else {
            throw UITreeDecodingError(description: "describe-ui JSON has no known platform")
        }
        let nodes = object["roots"] as? [[String: Any]] ?? []
        self.init(
            platform: platform,
            device: object["device"] as? String ?? "",
            screen: (object["screen"] as? [String: Any]).flatMap(UIScreenInfo.init(jsonObject:)),
            roots: try nodes.map { try UINode(jsonObject: $0, platform: platform) }
        )
        decodedContext = (object["context"] as? [String: Any]).map(UITreeContext.init(jsonObject:))
    }
}

extension UITreeContext {
    init(jsonObject object: [String: Any]) {
        let window = (object["window"] as? [String: Any]).flatMap { window -> Window? in
            guard let kind = (window["kind"] as? String).flatMap(Window.Kind.init(rawValue:)) else { return nil }
            return Window(title: window["title"] as? String, kind: kind, package: window["package"] as? String)
        }
        let logBox = (object["logbox"] as? [String: Any]).map { logBox in
            LogBox(logs: (logBox["logs"] as? NSNumber)?.intValue ?? 0, inspector: logBox["inspector"] as? Bool ?? false)
        }
        self.init(window: window, keyboard: object["keyboard"] as? Bool ?? false, logBox: logBox)
    }
}

extension UIScreenInfo {
    /// The describe-ui `screen` object; nil without a width and height.
    public init?(jsonObject object: [String: Any]) {
        guard let width = Self.double(object["width"]), let height = Self.double(object["height"]) else {
            return nil
        }
        let display = (object["display"] as? [String: Any]).flatMap { display -> ScreenDisplay? in
            guard let id = display["id"] as? String, let platformId = display["platformId"] as? String else { return nil }
            return ScreenDisplay(id: id, platformId: platformId)
        }
        self.init(
            width: width,
            height: height,
            scale: Self.double(object["scale"]),
            rotationDegrees: (object["rotation"] as? NSNumber)?.intValue,
            display: display,
            posture: (object["posture"] as? String).flatMap(Posture.init(rawValue:))
        )
    }

    fileprivate static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

extension UINode {
    init(jsonObject object: [String: Any], platform: DevicePlatform) throws {
        guard let roleName = object["role"] as? String, let role = UIRole(rawValue: roleName) else {
            throw UITreeDecodingError(description: "a node has no known role: \(object["role"] ?? "none")")
        }
        let state = object["state"] as? [String: Any] ?? [:]
        let native = object["native"] as? [String: Any]
        self.init(
            role: role,
            id: object["id"] as? String,
            label: object["label"] as? String,
            value: object["value"] as? String,
            frame: (object["frame"] as? [String: Any]).flatMap(UIFrame.init(jsonObject:)),
            enabled: object["enabled"] as? Bool,
            state: UIState(checked: state["checked"] as? Bool, selected: state["selected"] as? Bool, focused: state["focused"] as? Bool),
            native: platform == .ios ? .ios(IOSNativeAttributes(jsonObject: native ?? [:])) : .android(AndroidNativeAttributes(jsonObject: native ?? [:])),
            children: try (object["children"] as? [[String: Any]] ?? []).map { try UINode(jsonObject: $0, platform: platform) }
        )
    }
}

extension UIFrame {
    init?(jsonObject object: [String: Any]) {
        guard let x = UIScreenInfo.double(object["x"]), let y = UIScreenInfo.double(object["y"]),
              let width = UIScreenInfo.double(object["width"]), let height = UIScreenInfo.double(object["height"]) else {
            return nil
        }
        self.init(x: x, y: y, width: width, height: height)
    }
}

extension IOSNativeAttributes {
    init(jsonObject object: [String: Any]) {
        self.init(
            type: object["type"] as? String,
            role: object["role"] as? String,
            subrole: object["subrole"] as? String,
            roleDescription: object["roleDescription"] as? String,
            title: object["title"] as? String,
            help: object["help"] as? String,
            customActions: object["customActions"] as? [String] ?? [],
            contentRequired: object["contentRequired"] as? Bool,
            pid: (object["pid"] as? NSNumber)?.intValue,
            axFrame: object["axFrame"] as? String
        )
    }
}

extension AndroidNativeAttributes {
    init(jsonObject object: [String: Any]) {
        self.init(
            className: object["className"] as? String,
            resourceId: object["resourceId"] as? String,
            package: object["package"] as? String,
            pixelFrame: (object["pixelFrame"] as? [String: Any]).flatMap(UIFrame.init(jsonObject:)),
            text: object["text"] as? String,
            contentDescription: object["contentDescription"] as? String,
            hint: object["hint"] as? String,
            stateDescription: object["stateDescription"] as? String,
            roleDescription: object["roleDescription"] as? String,
            testTag: object["testTag"] as? String
        )
    }
}
