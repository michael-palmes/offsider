import Foundation

/// A lock screen PIN or password; it prints as withheld, so it never reaches a log, an error or JSON.
public struct UnlockCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Android passwords run to 64 characters on recent releases.
    public static let lengths = 4...64
    public static let pinLengths = 4...16

    public let text: String

    /// Nil unless `text` is 4 to 64 printable ASCII characters, which the helper types as key events, ignoring a trailing line break.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard trimmed.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }), Self.lengths.contains(trimmed.count) else { return nil }
        self.text = trimmed
    }

    /// 4 to 16 digits, which a PIN pad takes.
    public var isPIN: Bool { Self.pinLengths.contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber } }

    public var description: String { "<code withheld>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What Offsider knows about its last unlock of a device; the code is never part of it.
public struct UnlockAttemptRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The first key was about to go and no result followed: the run died, a key failed, or the marker predates outcomes.
        case started
        /// Typed in full, and the lock screen stayed up.
        case rejected
    }

    public let outcome: Outcome
    public let at: Date?
    /// `pin` or `password`, as the lock screen named it.
    public let credential: String?

    public init(outcome: Outcome, at: Date?, credential: String?) {
        self.outcome = outcome
        self.at = at
        self.credential = credential
    }

    private enum CodingKeys: String, CodingKey {
        case outcome, at, credential
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try container.decode(Outcome.self, forKey: .outcome)
        at = try container.decodeIfPresent(String.self, forKey: .at).flatMap { try? Date($0, strategy: .iso8601) }
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(at?.formatted(.iso8601), forKey: .at)
        try container.encode(credential, forKey: .credential)
    }

    /// `PIN` or `password`, else `code`.
    private var codeName: String {
        switch credential {
        case "pin": return "PIN"
        case "password": return "password"
        default: return "code"
        }
    }

    /// The cause in one sentence; `dated` is false for the run that just typed it.
    public func problem(name: String, dated: Bool = true, timeZone: TimeZone = .current) -> String {
        let when = dated ? at.map { " on " + Self.date($0, timeZone: timeZone) } ?? "" : ""
        switch outcome {
        case .rejected: return "The saved \(codeName) is wrong: \(name) stayed locked after Offsider typed it\(when)."
        case .started: return "Offsider can't tell if the saved \(codeName) is right: it has no result for its unlock of \(name)\(when)."
        }
    }

    /// The one fix, ending on the command; `device` is the key the code is saved under.
    public func fix(device: String) -> String {
        let save = UnlockCodeScreen.setCommand(device)
        switch outcome {
        case .rejected: return "Save the right one: `\(save)`"
        case .started: return "Save it again: `\(save)`"
        }
    }

    public var noRetry: String {
        let plural = codeName + "s"
        switch outcome {
        case .rejected: return "Offsider won't type it again: repeated wrong \(plural) can lock a phone out."
        case .started: return "Offsider won't type it until then: repeated wrong \(plural) can lock a phone out."
        }
    }

    /// Cause, fix and why Offsider won't retry, a line each, so the command stands alone.
    public func message(name: String, device: String, dated: Bool = true, timeZone: TimeZone = .current) -> String {
        [problem(name: name, dated: dated, timeZone: timeZone), fix(device: device), noRetry].joined(separator: "\n")
    }

    /// `30 Oct at 14:05`, local time.
    private static func date(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM 'at' HH:mm"
        return formatter.string(from: date)
    }
}

/// Offsider types a saved code once: any marker stops it typing again. A rejected code stays until it is saved again; an attempt with no result also goes once the device reads unlocked.
public struct UnlockAttemptLedger: Sendable {
    public static let directoryName = "unlock"
    static let maxMarkerBytes = 1024

    let root: String

    public init(root: String = OffsiderPrivateDirectory.root) {
        self.root = root
    }

    /// Nil with no marker; an empty or unreadable one, as earlier versions left, is an attempt with no result, dated by the file.
    public func lastAttempt(_ device: String) -> UnlockAttemptRecord? {
        let path = path(device)
        var info = stat()
        guard unsafe lstat(path, &info) == 0 else { return nil }
        if let data = UntrustedRead.contents(atPath: path, maxBytes: Self.maxMarkerBytes),
           let record = try? JSONDecoder().decode(UnlockAttemptRecord.self, from: data) {
            return record
        }
        return UnlockAttemptRecord(outcome: .started, at: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), credential: nil)
    }

    public func record(_ record: UnlockAttemptRecord, for device: String) throws {
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(Self.directoryName, root: root)
        try OffsiderPrivateDirectory.writeAtomically(try JSONEncoder().encode(record), named: Self.fileName(device), in: directory)
    }

    public func clear(_ device: String) {
        unsafe unlink(path(device))
    }

    /// For an unlocked device: it settles an attempt with no result, but a rejected code is still wrong.
    public func clearUnfinished(_ device: String) {
        guard lastAttempt(device)?.outcome != .rejected else { return }
        clear(device)
    }

    /// `device-<key>.failed`, with anything outside letters, digits, `.`, `_` and `-` replaced by `_`.
    static func fileName(_ device: String) -> String {
        let safe = String(device.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" })
        return "device-\(safe).failed"
    }

    private func path(_ device: String) -> String {
        ((root as NSString).appendingPathComponent(Self.directoryName) as NSString).appendingPathComponent(Self.fileName(device))
    }
}
