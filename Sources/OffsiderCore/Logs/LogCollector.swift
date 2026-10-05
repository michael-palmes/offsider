import Foundation

/// Applies `--raw`, `--grep`, redaction and `--max-lines` to entries as they arrive, keeping the newest.
public struct LogCollector {
    public let maxLines: Int
    public let keepsANSI: Bool
    /// Masks sensitive values in `message` and `raw` after `--grep` has matched the unredacted text.
    public let redacts: Bool
    /// False for `--follow`, which prints entries as they arrive and never reads them back.
    public let retainsEntries: Bool
    private let grep: NSRegularExpression?
    private var kept: [LogEntry] = []
    /// Entries that passed `--grep`, kept or not.
    public private(set) var matched = 0
    /// Values redacted in every entry that passed `--grep`, kept or not.
    public private(set) var redacted = 0

    /// `maxLines` 0 keeps everything; `grep` is a case-insensitive regular expression matched against the stripped message.
    public init(maxLines: Int, grep: String?, keepsANSI: Bool, redacts: Bool = false, retainsEntries: Bool = true) throws {
        guard maxLines >= 0 else {
            throw LogOptionError("--max-lines must be 0 (no limit) or more; got \(maxLines).")
        }
        self.maxLines = maxLines
        self.keepsANSI = keepsANSI
        self.redacts = redacts
        self.retainsEntries = retainsEntries
        self.grep = try grep.map(Self.compile)
    }

    public static func compile(_ pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw LogOptionError("Invalid --grep pattern: \(pattern). Use an ICU regular expression, and escape characters such as ( [ . * with a backslash to match them literally.")
        }
    }

    /// The entry as it should be shown, or nil when `--grep` rejects it.
    public func filter(_ entry: LogEntry) -> LogEntry? {
        shown(entry)?.entry
    }

    /// The shown entry and how many values were redacted in it: the most in its message or its raw line, which usually hold the same values.
    func shown(_ entry: LogEntry) -> (entry: LogEntry, redacted: Int)? {
        let stripped = LogText.stripANSI(entry.message)
        if let grep, grep.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) == nil {
            return nil
        }
        var shown = entry
        if !keepsANSI {
            shown.message = stripped
        }
        guard redacts else { return (shown, 0) }
        let message = LogRedactor.redact(shown.message)
        shown.message = message.text
        var count = message.count
        if let raw = shown.raw {
            let redactedRaw = LogRedactor.redact(raw)
            shown.raw = redactedRaw.text
            count = max(count, redactedRaw.count)
        }
        return (shown, count)
    }

    /// Filters and keeps the entry; returns it when it passed `--grep`.
    @discardableResult
    public mutating func add(_ entry: LogEntry) -> LogEntry? {
        guard let (shown, count) = shown(entry) else { return nil }
        matched += 1
        redacted += count
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
