import Foundation

/// Applies `--raw`, `--grep`, `--exclude`, redaction and `--max-lines` to entries as they arrive, keeping the newest.
public struct LogCollector {
    public let maxLines: Int
    public let keepsANSI: Bool
    /// Masks sensitive values in `message` and `raw` before `--grep` and `--exclude` match.
    public let redacts: Bool
    /// False for `--follow`, which prints entries as they arrive and never reads them back.
    public let retainsEntries: Bool
    private let grep: NSRegularExpression?
    private let excludes: [NSRegularExpression]
    private var kept: [LogEntry] = []
    /// Entries that passed `--grep` and `--exclude`, kept or not.
    public private(set) var matched = 0
    /// Values redacted in every entry that passed `--grep` and `--exclude`, kept or not.
    public private(set) var redacted = 0
    /// Entries that passed `--grep` but matched an `--exclude`.
    public private(set) var excluded = 0
    /// Entries that passed `--grep` and `--exclude`, kept or not, whose message the device's log cut short.
    public private(set) var cut = 0

    /// `maxLines` 0 keeps everything; `grep` and each `exclude` are case-insensitive regular expressions matched against the stripped, redacted message.
    public init(maxLines: Int, grep: String?, exclude: [String] = [], keepsANSI: Bool, redacts: Bool = false, retainsEntries: Bool = true) throws {
        guard maxLines >= 0 else {
            throw LogOptionError("--max-lines must be 0 (no limit) or more; got \(maxLines).")
        }
        self.maxLines = maxLines
        self.keepsANSI = keepsANSI
        self.redacts = redacts
        self.retainsEntries = retainsEntries
        self.grep = try grep.map { try Self.compile($0, option: "--grep") }
        self.excludes = try exclude.map { try Self.compile($0, option: "--exclude") }
    }

    public static func compile(_ pattern: String, option: String = "--grep") throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw LogOptionError("Invalid \(option) pattern: \(pattern). Use an ICU regular expression, and escape characters such as ( [ . * with a backslash to match them literally.")
        }
    }

    /// The entry as it should be shown, or nil when `--grep` or `--exclude` rejects it.
    public func filter(_ entry: LogEntry) -> LogEntry? {
        guard case .shown(let shown, _) = verdict(entry) else { return nil }
        return shown
    }

    enum Verdict {
        case unmatched
        case excluded
        /// The entry as shown and how many values were redacted in it: the most in its message or its raw line, which usually hold the same values.
        case shown(LogEntry, redacted: Int)
    }

    /// Redaction runs first, so `--grep` and `--exclude` see only what is shown and never answer yes or no about a redacted value.
    func verdict(_ entry: LogEntry) -> Verdict {
        let stripped = LogText.stripANSI(entry.message)
        var count = 0
        var matched = stripped
        var shown = entry
        if redacts {
            let message = LogRedactor.redact(stripped)
            matched = message.text
            count = message.count
            shown.message = keepsANSI ? LogRedactor.redact(entry.message).text : message.text
            if let raw = shown.raw {
                let redactedRaw = LogRedactor.redact(raw)
                shown.raw = redactedRaw.text
                count = max(count, redactedRaw.count)
            }
        } else if !keepsANSI {
            shown.message = stripped
        }
        let range = NSRange(matched.startIndex..., in: matched)
        if let grep, grep.firstMatch(in: matched, range: range) == nil {
            return .unmatched
        }
        if excludes.contains(where: { $0.firstMatch(in: matched, range: range) != nil }) {
            return .excluded
        }
        return .shown(shown, redacted: count)
    }

    /// Filters and keeps the entry; returns it when it passed `--grep` and `--exclude`.
    @discardableResult
    public mutating func add(_ entry: LogEntry) -> LogEntry? {
        let shown: LogEntry
        switch verdict(entry) {
        case .unmatched:
            return nil
        case .excluded:
            excluded += 1
            return nil
        case .shown(let entry, let count):
            shown = entry
            redacted += count
        }
        matched += 1
        if shown.truncated { cut += 1 }
        guard retainsEntries else { return shown }
        kept.append(shown)
        if maxLines > 0, kept.count >= maxLines * 2 {
            kept.removeFirst(kept.count - maxLines)
        }
        return shown
    }

    /// The newest `maxLines` matching entries, oldest first.
    public var entries: [LogEntry] {
        maxLines > 0 ? Array(kept.suffix(maxLines)) : kept
    }

    /// Matching entries left out by `--max-lines`.
    public var truncated: Int {
        matched - entries.count
    }
}
