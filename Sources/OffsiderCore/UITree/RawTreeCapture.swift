import Foundation

/// The platform's unmapped tree beside the describe-ui screen: what the committed tree goldens keep as their raw file.
public struct RawTreeCapture: Sendable {
    public var platform: DevicePlatform
    public var screen: UIScreenInfo?
    /// iOS: the idb accessibility JSON; Android: the helper's dump reply.
    public var source: Data

    public init(platform: DevicePlatform, screen: UIScreenInfo?, source: Data) {
        self.platform = platform
        self.screen = screen
        self.source = source
    }

    public static func render(platform: DevicePlatform, screen: UIScreenInfo?, source: Data) -> Data {
        let head = OrderedJSON.object([
            ("platform", .string(platform.rawValue)),
            ("screen", screen.map { $0.jsonValue(on: platform) } ?? .null),
        ]).rendered(compact: true)
        return Data((head.dropLast() + ",\"source\":").utf8) + source + Data("}".utf8)
    }

    public init(jsonData: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let platformName = object["platform"] as? String, let platform = DevicePlatform(rawValue: platformName),
              let source = object["source"] else {
            throw UITreeDecodingError(description: "a raw tree capture needs a platform and a source")
        }
        self.init(
            platform: platform,
            screen: (object["screen"] as? [String: Any]).flatMap(UIScreenInfo.init(jsonObject:)),
            source: try JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed])
        )
    }
}
