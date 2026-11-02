import Foundation

/// Whether what a screenshot reads shows a target's label, as a person checks a button by eye.
public enum ShownText {
    /// True when `read`, the lines recognised over the target, hold its whole label, whatever the case, spacing or punctuation; a label under two letters proves nothing.
    public static func shows(label: String, in read: [String]) -> Bool {
        let wanted = letters(of: label)
        guard wanted.count >= 2 else { return false }
        return letters(of: read.joined(separator: " ")).contains(wanted)
    }

    private static func letters(of text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}

extension CoverVerdict {
    /// Android's drawing order puts only an empty view over the target, unlabelled and taking no presses: the tree cannot tell a screen's own wrapper from a veil, so what shows there decides.
    public var isEmptyViewDoubt: Bool {
        evidence == .drawingOrder && !isConfident && !cover.isActionable && cover.normalizedLabel == nil
            && !cover.children.contains { $0.flattened().contains(where: \.isTelling) }
    }
}
