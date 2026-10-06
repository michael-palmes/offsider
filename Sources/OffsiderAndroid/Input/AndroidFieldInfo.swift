import Foundation

/// The focused field as the helper names it: its class, id and `InputType` bits.
struct AndroidFieldInfo: Equatable, Sendable {
    var className: String?
    var resourceId: String?
    var inputType: Int?

    /// `android.widget.EditText, id amount, inputType number|decimal`.
    var description: String {
        var parts: [String] = []
        if let className { parts.append(className) }
        if let resourceId { parts.append("id \(resourceId)") }
        if let inputType { parts.append("inputType \(Self.describe(inputType))") }
        return parts.joined(separator: ", ")
    }

    /// `InputType`'s class, then its variation or flags, as `text|email`, `number|signed|decimal` or `phone`.
    static func describe(_ bits: Int) -> String {
        let kind = bits & 0x0F
        let variation = bits & 0xFF0
        let flags = bits & 0xFFF000
        switch kind {
        case 0:
            return "none"
        case 1:
            let variations = [0x10: "uri", 0x20: "email", 0x30: "email-subject", 0x60: "person-name", 0x70: "postal-address", 0x80: "password", 0x90: "visible-password", 0xA0: "web-edit-text", 0xD0: "web-email", 0xE0: "web-password"]
            var parts = ["text"]
            if let name = variations[variation] { parts.append(name) }
            if flags & 0x20000 != 0 { parts.append("multi-line") }
            return parts.joined(separator: "|")
        case 2:
            var parts = ["number"]
            if flags & 0x1000 != 0 { parts.append("signed") }
            if flags & 0x2000 != 0 { parts.append("decimal") }
            if variation == 0x10 { parts.append("password") }
            return parts.joined(separator: "|")
        case 3:
            return "phone"
        case 4:
            return ["datetime", variation == 0x10 ? "date" : variation == 0x20 ? "time" : nil].compactMap { $0 }.joined(separator: "|")
        default:
            return "0x" + String(bits, radix: 16)
        }
    }
}
