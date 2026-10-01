import Foundation

/// Decode type for `AccessibilityFetcher.isTransientPointFallback`; commands use `UINode`.
struct AccessibilityElement: Decodable {
    struct Frame: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let type: String?
    let frame: Frame?
    let children: [AccessibilityElement]?
    let role: String?

    let AXLabel: String?
    let AXUniqueId: String?
    let AXIdentifier: String?
    let AXValue: String?

    enum CodingKeys: String, CodingKey {
        case type
        case frame
        case children
        case role
        case AXLabel
        case AXUniqueId
        case AXIdentifier
        case AXValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        type = try Self.decodeOptionalScalarString(from: container, forKey: .type)
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        children = try container.decodeIfPresent([AccessibilityElement].self, forKey: .children)
        role = try Self.decodeOptionalScalarString(from: container, forKey: .role)
        AXLabel = try Self.decodeOptionalScalarString(from: container, forKey: .AXLabel)
        AXUniqueId = try Self.decodeOptionalScalarString(from: container, forKey: .AXUniqueId)
        AXIdentifier = try Self.decodeOptionalScalarString(from: container, forKey: .AXIdentifier)
        AXValue = try Self.decodeOptionalScalarString(from: container, forKey: .AXValue)
    }

    private static func decodeOptionalScalarString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        if !container.contains(key) {
            return nil
        }
        if try container.decodeNil(forKey: key) {
            return nil
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Bool.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    var normalizedLabel: String? {
        trimmed(AXLabel)
    }

    var normalizedUniqueId: String? {
        trimmed(AXUniqueId) ?? trimmed(AXIdentifier)
    }

    var normalizedValue: String? {
        trimmed(AXValue)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
