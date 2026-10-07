import Foundation

/// `launchctl list` inside a simulator (`PID<tab>Status<tab>Label`), read for the apps it runs.
public enum SimLaunchctl {
    public struct App: Equatable, Sendable {
        public let bundleID: String
        public let pid: Int

        public init(bundleID: String, pid: Int) {
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    static let appPrefix = "UIKitApplication:"

    /// Running `UIKitApplication:<bundle>[…]` jobs, the newest (highest pid) first; a job shown as `-` is not running.
    public static func runningApps(_ listing: String) -> [App] {
        listing.split(whereSeparator: \.isNewline).compactMap { line -> App? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let pid = Int(fields[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            let label = fields[2].trimmingCharacters(in: .whitespaces)
            guard label.hasPrefix(appPrefix) else { return nil }
            let bundleID = label.dropFirst(appPrefix.count).prefix { $0 != "[" }
            return bundleID.isEmpty ? nil : App(bundleID: String(bundleID), pid: pid)
        }
        .sorted { $0.pid > $1.pid }
    }

    /// The app most likely in front: the newest one outside Apple's own (Spotlight and widget renderers run in the background); nil when only Apple's run.
    public static func likelyForeground(_ listing: String) -> App? {
        runningApps(listing).first { !$0.bundleID.hasPrefix("com.apple.") }
    }
}
