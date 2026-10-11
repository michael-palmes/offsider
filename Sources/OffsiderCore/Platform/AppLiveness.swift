import Foundation

/// A running app's process, by pid and start time, so a restarted app is never taken for the one seen before.
public struct AppProcess: Equatable, Sendable {
    public let pid: Int
    /// The kernel's start time where one read gives it (iOS); nil on Android, whose pids are not reused soon.
    public let started: UInt64?

    public init(pid: Int, started: UInt64? = nil) {
        self.pid = pid
        self.started = started
    }

    /// The same process: the pid matches, and so does the start time when both are known.
    public func isSame(as other: AppProcess) -> Bool {
        pid == other.pid && (started == nil || other.started == nil || started == other.started)
    }
}

/// What one liveness read found.
public enum AppLiveness: Equatable, Sendable {
    case running(AppProcess)
    case notRunning
    /// Nothing cheap could tell, which counts neither for nor against the app.
    case unknown
}

/// What a device recorded about a crash: an iOS report file, or the exception class or signal Android logged.
public enum AppCrashReport: Equatable, Sendable {
    case file(String)
    case cause(String)
    /// No report yet in this folder, where macOS can take many seconds to write one.
    case pending(directory: String)
}

/// Optional capability: whether an app's process runs, so a wait can tell an app that crashed from one still loading.
@MainActor
public protocol AppLivenessReading: DeviceBackend {
    /// `seen` is the process read before and `tree` the latest tree; `mayList` allows a slower process listing when neither can tell.
    func appLiveness(_ appID: String, seen: AppProcess?, tree: UITree?, mayList: Bool, on id: DeviceID) async -> AppLiveness
    /// What the device recorded about `process` stopping after `since`; nil when it recorded nothing Offsider can read.
    func crashReport(_ appID: String, process: AppProcess, since: Date, on id: DeviceID) async -> AppCrashReport?
}

/// Reads liveness every 2 s and calls a crash only when a process seen running is gone or replaced on two reads at least 1 s apart.
public struct AppLivenessWatch: Sendable {
    public static let interval: TimeInterval = 2
    public static let confirmAfter: TimeInterval = 1
    public static let listEvery: TimeInterval = 4

    public enum Verdict: Equatable, Sendable {
        case alive
        /// No process has been seen yet, so nothing can crash.
        case unseen
        /// The seen process was missing once; one more read decides.
        case suspect
        case crashed(AppProcess)
    }

    public private(set) var seen: AppProcess?
    /// The process `--restart` stopped: a read made while it still exits must not take it for the app.
    public var stopped: AppProcess?
    private var missSince: TimeInterval?
    private var lastRead: TimeInterval?
    private var lastListing: TimeInterval?

    public init() {}

    public var hasPendingMiss: Bool { missSince != nil }

    /// Every 2 s, or 1 s after a miss to confirm it.
    public func isDue(at now: TimeInterval) -> Bool {
        guard let lastRead else { return true }
        return now - lastRead >= (missSince == nil ? Self.interval : Self.confirmAfter)
    }

    public func readRecently(at now: TimeInterval, within seconds: TimeInterval) -> Bool {
        lastRead.map { now - $0 < seconds } ?? false
    }

    /// True at most every 4 s; a read given it may list processes.
    public mutating func takeListing(at now: TimeInterval) -> Bool {
        if let lastListing, now - lastListing < Self.listEvery { return false }
        lastListing = now
        return true
    }

    public mutating func record(_ reading: AppLiveness, at now: TimeInterval) -> Verdict {
        lastRead = now
        guard let seen else {
            if case .running(let process) = reading, !(stopped.map(process.isSame) ?? false) {
                self.seen = process
                return .alive
            }
            return .unseen
        }
        switch reading {
        case .unknown:
            return missSince == nil ? .alive : .suspect
        case .running(let process) where process.isSame(as: seen):
            missSince = nil
            return .alive
        case .running, .notRunning:
            guard let since = missSince else {
                missSince = now
                return .suspect
            }
            return now - since >= Self.confirmAfter ? .crashed(seen) : .suspect
        }
    }
}

/// iOS simulator liveness from the tree's application pid, one `sysctl` for a process already seen, or a `launchctl list` inside the simulator.
public enum SimulatorAppLiveness {
    /// The pid the tree's application element reports, a process on this Mac.
    public static func applicationPID(in tree: UITree) -> Int? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        guard let app = nodes.first(where: { $0.role == .application }) ?? tree.roots.first,
              case .ios(let native) = app.native else { return nil }
        return native.pid
    }

    /// `bundleOf` maps a pid to its app's bundle id; `startOf` reads a live pid's start time; `listing` runs `launchctl list` in the simulator.
    public static func read(
        _ bundleID: String,
        seen: AppProcess?,
        tree: UITree?,
        mayList: Bool,
        bundleOf: (Int) -> String?,
        startOf: (Int) -> UInt64?,
        listing: () async -> String?
    ) async -> AppLiveness {
        let treePID = tree.flatMap(applicationPID)
        func process(_ pid: Int) -> AppProcess? {
            startOf(pid).map { AppProcess(pid: pid, started: $0) }
        }
        if let seen {
            if let current = process(seen.pid), current.isSame(as: seen) { return .running(seen) }
            if let treePID, treePID != seen.pid, bundleOf(treePID) == bundleID, let replacement = process(treePID) {
                return .running(replacement)
            }
            return .notRunning
        }
        if let treePID {
            guard bundleOf(treePID) == bundleID, let found = process(treePID) else { return .unknown }
            return .running(found)
        }
        guard mayList, let text = await listing() else { return .unknown }
        guard let app = SimLaunchctl.runningApps(text).first(where: { $0.bundleID == bundleID }) else { return .notRunning }
        return process(app.pid).map(AppLiveness.running) ?? .notRunning
    }
}
