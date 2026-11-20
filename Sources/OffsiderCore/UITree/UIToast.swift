import Foundation

/// An Android Toast the app in scope raised lately, which no tree or late screenshot shows.
public struct UIToast: Equatable, Sendable {
    /// Tells one toast from another within a command (the helper's process and count); never printed.
    public var key: String
    public var text: String
    public var package: String
    /// How long before the read the toast was raised.
    public var ageMs: Int

    /// The helper keeps toasts this long; a read lists none older.
    public static let maximumAgeMs = 30_000
    /// Android shows a long toast for 3.5 s (`Toast.LENGTH_LONG`), so one older than this has left the screen.
    public static let onScreenMs = 3_500

    public init(key: String, text: String, package: String, ageMs: Int) {
        self.key = key
        self.text = text
        self.package = package
        self.ageMs = ageMs
    }

    /// As output shows it: a masked label hidden, a text `mask`'s patterns touch hidden whole, else secrets redacted; `count` adds one per value hidden.
    public func redacted(_ mask: TreeValueMask, count: inout Int) -> UIToast {
        var copy = self
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if mask.hides(id: nil, label: trimmed) {
            copy.text = mask.maskedLabel(text, id: nil)
            if copy.text != text { count += 1 }
        } else {
            copy.text = UITree.redactText(text, mask: mask, count: &count, whole: true)
        }
        return copy
    }

    /// `"Draft saved" from com.example.app, 2 s ago`.
    public var summary: String {
        "\(UITreeRenderer.quoted(SelectorText.truncated(text, limit: 80))) from \(TerminalText.bareOrQuoted(package)), \(Self.age(ageMs))"
    }

    static func age(_ ms: Int) -> String {
        if ms < 1000 { return "just now" }
        return "\(ms / 1000) s ago" + (ms > onScreenMs ? ", off screen by now" : "")
    }

    var jsonValue: OrderedJSON {
        .object([("text", .string(text)), ("package", .string(package)), ("ageMs", .integer(ageMs))])
    }

    init?(jsonObject object: [String: Any]) {
        guard let text = object["text"] as? String, let package = object["package"] as? String else { return nil }
        self.init(key: "", text: text, package: package, ageMs: (object["ageMs"] as? NSNumber)?.intValue ?? 0)
    }

    /// Whether `text` names this toast: the whole text, as `--label` matches a label.
    public func matches(_ wanted: String) -> Bool {
        SelectorText.folded(text) == SelectorText.folded(wanted)
    }
}
