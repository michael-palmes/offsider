import Foundation

/// A lock screen PIN or password; it prints as withheld, so it never reaches a log, an error or JSON.
public struct UnlockCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Android passwords run to 64 characters on recent releases.
    public static let lengths = 4...64
    public static let pinLengths = 4...16

    public let text: String

    /// Nil unless `text` is 4 to 64 printable ASCII characters, which `input text` can type, ignoring a trailing line break.
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

/// Devices whose last unlock attempt failed: Offsider types a saved code once, and not again until the device is unlocked by hand or the code is saved again.
public struct UnlockAttemptLedger: Sendable {
    public static let directoryName = "unlock"

    let root: String

    public init(root: String = OffsiderPrivateDirectory.root) {
        self.root = root
    }

    public func hasFailed(_ device: String) -> Bool {
        var info = stat()
        return lstat(path(device), &info) == 0
    }

    public func recordFailure(_ device: String) throws {
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(Self.directoryName, root: root)
        try OffsiderPrivateDirectory.writeAtomically(Data(), named: Self.fileName(device), in: directory)
    }

    public func clear(_ device: String) {
        unlink(path(device))
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
