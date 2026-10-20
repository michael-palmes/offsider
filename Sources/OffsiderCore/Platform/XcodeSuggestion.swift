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

/// The Xcode to name in a fix: the newest Apple-signed one in /Applications, never an unsigned bundle or the one just refused.
public struct XcodeSuggestion: Equatable, Sendable {
    /// The fix when no Apple-signed Xcode 26 or later is left to select.
    public static let install = XcodeSuggestion(developerDirectory: nil).install

    /// The developer directory to select; nil when no other Apple-signed Xcode was found.
    public let developerDirectory: String?
    /// The oldest Xcode major the fix may name.
    public let minimumMajor: Int

    public init(developerDirectory: String?, minimumMajor: Int = 26) {
        self.developerDirectory = developerDirectory
        self.minimumMajor = minimumMajor
    }

    /// The newest Apple-signed bundle at `minimumMajor` or later whose developer directory, once symlinks are resolved, is not `rejected`.
    public init(bundles: [XcodeBundle], rejecting rejected: String? = nil, minimumMajor: Int = 26) {
        func resolved(_ path: String) -> String { DeveloperDirectoryTrust.realPath(path) ?? path }
        let skipped = rejected.map(resolved)
        let candidates = Self.ordered(bundles).filter { ($0.version?.split(separator: ".").first.flatMap { Int($0) } ?? 0) >= minimumMajor }
        self.init(developerDirectory: candidates.first { resolved($0.developerDirectory) != skipped }?.developerDirectory, minimumMajor: minimumMajor)
    }

    /// This suggestion, or `developerDirectory` when it names none.
    public func or(_ developerDirectory: String) -> XcodeSuggestion {
        self.developerDirectory == nil ? XcodeSuggestion(developerDirectory: developerDirectory, minimumMajor: minimumMajor) : self
    }

    public var install: String { "Install Xcode \(minimumMajor) or later from the Mac App Store or developer.apple.com." }
    /// The fix that needs an administrator password, or the install when there is nothing to select.
    public var select: String { developerDirectory.map { "sudo xcode-select -s \($0)" } ?? install }
    /// For a CoreDevice too old: select the Xcode and run its first launch, which updates CoreDevice, even when it is already selected.
    public var firstLaunch: String {
        developerDirectory.map { "sudo xcode-select -s \($0) && sudo xcodebuild -runFirstLaunch" } ?? install
    }
    /// The same choice with no sudo: `export` for a person's shell; for an agent, whose shell forgets it, a prefix on each command.
    public var environment: String? { environment(for: .current) }

    public func environment(for audience: ErrorAudience) -> String? {
        developerDirectory.map { audience == .person ? "export DEVELOPER_DIR=\($0)" : "DEVELOPER_DIR=\($0) offsider …" }
    }

    /// `message` with the no-sudo choice after it, for a message whose `Try:` line carries `select`.
    public func adding(to message: String) -> String { adding(to: message, audience: .current) }

    public func adding(to message: String, audience: ErrorAudience) -> String {
        guard let environment = environment(for: audience) else { return message }
        return audience == .person ? "\(message) Without sudo, run `\(environment)` instead." : "\(message) Without sudo, run each command as `\(environment)` instead."
    }

    /// One sentence naming both, for a doctor hint.
    public var advice: String { advice(for: .current) }

    public func advice(for audience: ErrorAudience) -> String {
        guard let environment = environment(for: audience) else { return install }
        return audience == .person ? "Select it with `\(select)`, or without sudo: `\(environment)`." : "Select it with `\(select)`, or without sudo run each command as `\(environment)`."
    }

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
            return XcodeBundle(path: path, version: info?["CFBundleShortVersionString"] as? String, appleSigned: validator(path) == nil)
        }
    }

    /// Scanned once per process, only when a fix needs it.
    public static let installed = scan()
    public static let current = XcodeSuggestion(bundles: installed)

    /// The newest Apple-signed Xcode other than the one at `developerDirectory`, which was just refused or failed.
    public static func instead(of developerDirectory: String) -> XcodeSuggestion {
        XcodeSuggestion(bundles: installed, rejecting: developerDirectory)
    }

    /// The newest Apple-signed Xcode at `major` or later.
    public static func atLeast(_ major: Int) -> XcodeSuggestion {
        XcodeSuggestion(bundles: installed, minimumMajor: major)
    }
}
