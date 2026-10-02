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

    /// Up to `limit` candidates close to `query`, best first: a case difference, then containment, then a small edit distance.
    public static func suggestions(for query: String, among candidates: [String], limit: Int = 3) -> [String] {
        let target = folded(query).lowercased()
        guard !target.isEmpty, limit > 0 else {
            return []
        }
        let maxDistance = max(1, min(3, target.count / 4))
        var tiers: [[String]] = [[], [], []]
        var seen = Set<String>()

        for candidate in candidates where seen.insert(candidate).inserted {
            let other = folded(candidate).lowercased()
            guard !other.isEmpty else { continue }
            if other == target {
                tiers[0].append(candidate)
            } else if contains(other, target) {
                tiers[1].append(candidate)
            } else if editDistance(target, other, limit: maxDistance) != nil {
                tiers[2].append(candidate)
            }
        }
        return Array(tiers.joined().prefix(limit))
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

    /// Either side contains the other, when the shorter one has at least 3 characters.
    private static func contains(_ lhs: String, _ rhs: String) -> Bool {
        let (shorter, longer) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        return shorter.count >= 3 && longer.contains(shorter)
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
