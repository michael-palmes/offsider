import Foundation

/// Text matching that forgives what a person cannot see: typographic quotes, odd spaces and invisible marks.
public enum SelectorText {
    private static let singleQuotes: Set<Unicode.Scalar> = ["\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "\u{00B4}", "\u{0060}", "\u{02BC}"]
    private static let doubleQuotes: Set<Unicode.Scalar> = ["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}"]
    private static let hyphens: Set<Unicode.Scalar> = ["\u{2010}", "\u{2011}", "\u{2212}"]

    /// NFKC with ASCII quotes and hyphens, invisible format marks removed and whitespace runs collapsed; case is kept.
    public static func folded(_ text: String) -> String {
        let compatible = mapped(mapped(text).precomposedStringWithCompatibilityMapping)
        return compatible
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// `text` cut to `limit` characters, the last one an ellipsis, when it is longer.
    public static func truncated(_ text: String, limit: Int = 60) -> String {
        guard limit > 0, text.count > limit else {
            return text
        }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// How a near miss relates to the text asked for, ignoring case: `prefix` and `contains` hold all of it.
    public enum Closeness: String, Sendable {
        case `case`
        case prefix
        case contains
        case similar
    }

    /// A candidate close to the text asked for, and how close.
    public struct NearMatch: Equatable, Sendable {
        public let text: String
        public let closeness: Closeness

        public init(text: String, closeness: Closeness) {
            self.text = text
            self.closeness = closeness
        }
    }

    /// Up to `limit` candidates close to `query`, best first: a case difference, then a prefix, containment, a candidate the query holds, then a small edit distance.
    public static func nearMatches(for query: String, among candidates: [String], limit: Int = 3) -> [NearMatch] {
        let target = folded(query).lowercased()
        guard !target.isEmpty, limit > 0 else {
            return []
        }
        let maxDistance = max(1, min(3, target.count / 4))
        let closeness: [Closeness] = [.case, .prefix, .contains, .similar, .similar]
        var tiers: [[String]] = Array(repeating: [], count: closeness.count)
        var seen = Set<String>()

        for candidate in candidates where seen.insert(candidate).inserted {
            let other = folded(candidate).lowercased()
            guard !other.isEmpty else { continue }
            if other == target {
                tiers[0].append(candidate)
            } else if target.count >= 3, other.hasPrefix(target) {
                tiers[1].append(candidate)
            } else if target.count >= 3, other.contains(target) {
                tiers[2].append(candidate)
            } else if other.count >= 3, target.contains(other) {
                tiers[3].append(candidate)
            } else if editDistance(target, other, limit: maxDistance) != nil {
                tiers[4].append(candidate)
            }
        }
        let ranked = tiers.enumerated().flatMap { tier, texts in texts.map { NearMatch(text: $0, closeness: closeness[tier]) } }
        return Array(ranked.prefix(limit))
    }

    /// True when the folded `text` holds the folded `query`, in the same case; an empty query holds nothing.
    public static func folded(_ text: String, contains query: String) -> Bool {
        let wanted = folded(query)
        return !wanted.isEmpty && folded(text).contains(wanted)
    }

    /// The text `--label-contains` should name to match `label`: `query` when the label holds it, else the label's own spelling of it in another case.
    public static func containedText(of query: String, in label: String) -> String? {
        let wanted = folded(query)
        guard !wanted.isEmpty else { return nil }
        let haystack = folded(label)
        if haystack.contains(wanted) { return wanted }
        return haystack.range(of: wanted, options: [.caseInsensitive]).map { String(haystack[$0]) }
    }

    private static func mapped(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isInvisible(scalar) {
                continue
            } else if singleQuotes.contains(scalar) {
                scalars.append("'")
            } else if doubleQuotes.contains(scalar) {
                scalars.append("\"")
            } else if hyphens.contains(scalar) {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060, 0x2066...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// The Levenshtein distance when it is at most `limit`, else nil.
    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int? {
        let a = Array(lhs)
        let b = Array(rhs)
        guard abs(a.count - b.count) <= limit else {
            return nil
        }
        guard !a.isEmpty, !b.isEmpty else {
            return max(a.count, b.count)
        }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMinimum = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit {
                return nil
            }
            previous = current
        }
        let distance = previous[b.count]
        return distance <= limit ? distance : nil
    }
}
