import Foundation

/// JSON with object keys kept in insertion order, which `JSONEncoder` does not guarantee.
enum OrderedJSON {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null

    static func optional<T>(_ value: T?, _ wrap: (T) -> OrderedJSON) -> OrderedJSON {
        value.map(wrap) ?? .null
    }

    func rendered() -> String {
        var output = ""
        write(to: &output, indent: 0)
        return output
    }

    private func write(to output: inout String, indent: Int) {
        switch self {
        case .object(let members):
            guard !members.isEmpty else {
                output += "{}"
                return
            }
            let inner = String(repeating: " ", count: indent + 2)
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += inner
                Self.writeString(member.0, to: &output)
                output += ": "
                member.1.write(to: &output, indent: indent + 2)
                output += index == members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: " ", count: indent) + "}"
        case .array(let elements):
            guard !elements.isEmpty else {
                output += "[]"
                return
            }
            let inner = String(repeating: " ", count: indent + 2)
            output += "[\n"
            for (index, element) in elements.enumerated() {
                output += inner
                element.write(to: &output, indent: indent + 2)
                output += index == elements.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: " ", count: indent) + "]"
        case .string(let value):
            Self.writeString(value, to: &output)
        case .number(let value):
            output += Self.formatNumber(value)
        case .integer(let value):
            output += String(value)
        case .bool(let value):
            output += value ? "true" : "false"
        case .null:
            output += "null"
        }
    }

    static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
