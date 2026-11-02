import CryptoKit
import Foundation

/// One iOS simulator's last capture, as digests: a swipe-up unlock can freeze its display while its tree moves on, so a picture alone looks fine.
public struct FrozenDisplayRecord: Equatable, Sendable {
    public static let version = 1
    public static let maximumBytes = 1024

    public var image: String
    public var tree: String

    public init(image: String, tree: String) {
        self.image = image
        self.tree = tree
    }

    /// `<first 16 hex of SHA-256 of device>.frame.json`, beside the tree cache's own file.
    public static func fileName(device: String) -> String {
        hex(SHA256.hash(data: Data(device.utf8)).prefix(8)) + ".frame.json"
    }

    public static func digest(pixels: Data) -> String {
        hex(SHA256.hash(data: pixels))
    }

    /// What the elements on screen are and where; values stay out, as they can hold what a person typed, and so does a screen beneath a page, which draws nothing.
    public static func digest(tree: UITree) -> String {
        let viewport = tree.viewport
        let lines = LiveText.withoutBeneath(tree).roots.flatMap { $0.flattened() }.compactMap { node -> String? in
            if let viewport, let frame = node.frame, !frame.isVisible(in: viewport) { return nil }
            let frame = node.frame.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? ""
            return [node.role.rawValue, node.id ?? "", node.label ?? "", frame].joined(separator: "\u{1F}")
        }
        return hex(SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)))
    }

    /// The same picture over a tree that changed.
    public func looksFrozen(after previous: FrozenDisplayRecord?) -> Bool {
        guard let previous else { return false }
        return previous.image == image && previous.tree != tree
    }

    public func encoded() -> Data {
        Data(OrderedJSON.object([("v", .integer(Self.version)), ("image", .string(image)), ("tree", .string(tree))]).rendered(compact: true).utf8)
    }

    public init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (object["v"] as? NSNumber)?.intValue == Self.version,
              let image = object["image"] as? String, let tree = object["tree"] as? String else { return nil }
        self.init(image: image, tree: tree)
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { unsafe String(format: "%02x", $0) }.joined()
    }
}
