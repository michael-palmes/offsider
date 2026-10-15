import Foundation

/// An `Xcode*.app` in /Applications, with its version and whether Apple signed it.
public struct XcodeBundle: Equatable, Sendable {
    public let path: String
    public let version: String?
    public let appleSigned: Bool

    public init(path: String, version: String?, appleSigned: Bool) {
        self.path = path
        self.version = version
        self.appleSigned = appleSigned
    }

    public var developerDirectory: String { path + "/Contents/Developer" }
}

/// The Xcode to name in a fix: the newest Apple-signed one in /Applications, never an unsigned bundle.
public struct XcodeSuggestion: Equatable, Sendable {
    public static let placeholder = "/Applications/Xcode.app/Contents/Developer"

    /// The developer directory to select; the placeholder when no signed Xcode was found.
    public let developerDirectory: String

    public init(developerDirectory: String) {
        self.developerDirectory = developerDirectory
    }

    public init(bundles: [XcodeBundle]) {
        self.init(developerDirectory: Self.ordered(bundles).first?.developerDirectory ?? Self.placeholder)
    }

    /// The fix that needs an administrator password.
    public var select: String { "sudo xcode-select -s \(developerDirectory)" }
    /// The same choice for this shell only, with no sudo.
    public var environment: String { "export DEVELOPER_DIR=\(developerDirectory)" }
    /// The no-sudo choice, for a message whose `Try:` line carries `select`.
    public var withoutSudo: String { "Without sudo, run `\(environment)` instead." }
    /// One sentence naming both, for a doctor hint.
    public var advice: String { "Select it with `\(select)`, or without sudo: `\(environment)`." }

    /// Apple-signed bundles, newest version first; `Xcode.app` wins a tie, then the name.
    public static func ordered(_ bundles: [XcodeBundle]) -> [XcodeBundle] {
        bundles.filter(\.appleSigned).sorted { lhs, rhs in
            let order = compare(lhs.version, rhs.version)
            if order != .orderedSame { return order == .orderedDescending }
            let lhsPlain = lhs.path.hasSuffix("/Xcode.app")
            let rhsPlain = rhs.path.hasSuffix("/Xcode.app")
            if lhsPlain != rhsPlain { return lhsPlain }
            return lhs.path < rhs.path
        }
    }

    static func compare(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        let left = (lhs ?? "").split(separator: ".").map { Int($0) ?? 0 }
        let right = (rhs ?? "").split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// `Xcode*.app` bundles in `directory` with a `Contents/Developer`, each checked with `validator`.
    public static func scan(
        _ directory: String = "/Applications",
        validator: DeveloperDirectoryTrust.Validator = DeveloperDirectoryTrust.appleSigned
    ) -> [XcodeBundle] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.compactMap { name in
            let path = directory + "/" + name
            guard FileManager.default.fileExists(atPath: path + "/Contents/Developer") else { return nil }
            let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
            return XcodeBundle(path: path, version: info?["CFBundleShortVersionString"] as? String, appleSigned: validator(path))
        }
    }

    /// Scanned once per process, only when a fix needs it.
    public static let current = XcodeSuggestion(bundles: scan())
}
