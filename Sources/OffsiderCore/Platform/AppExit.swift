import Foundation

/// The app a read showed: the application's process on an iOS simulator, the package in front on Android, with the id `app launch` takes when known.
public struct ShownApp: Equatable, Sendable {
    public let pid: Int?
    public let appID: String?

    public init(pid: Int?, appID: String?) {
        self.pid = pid
        self.appID = appID
    }

    /// The app `tree` names, from the tree alone; nil when it names none.
    public static func of(_ tree: UITree) -> ShownApp? {
        switch tree.platform {
        case .ios:
            return SimulatorAppLiveness.applicationPID(in: tree).map { ShownApp(pid: $0, appID: nil) }
        case .android:
            return (try? ForegroundApp.identifier(in: tree, pathForPID: { _ in nil })).map { ShownApp(pid: nil, appID: $0) }
        }
    }

    /// A read that names another process on iOS or another package on Android, or no app at all.
    public func differs(from other: ShownApp?) -> Bool {
        guard let other else { return true }
        if let pid { return pid != other.pid }
        return appID != other.appID
    }
}

/// The app a command began on stopped while it waited or checked an input.
public struct AppExitError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let message: String
    /// A crash report or an Android exception names it; else nothing on the device says why.
    public let crashed: Bool
    public let hint: String?

    public var errorDescription: String? { message }
    public var description: String { message }

    public init(_ app: ShownApp, report: AppCrashReport?, device: DeviceID) {
        let name = app.appID ?? "The app"
        switch report {
        case .file(let path):
            message = "\(name) crashed: its process stopped. Crash report: \(path)"
            crashed = true
        case .cause(let cause):
            message = "\(name) crashed: it stopped with \(cause)."
            crashed = true
        case .pending(let directory):
            message = "\(name) stopped: its process is gone, and no crash report names it yet; look in \(directory) for the newest one."
            crashed = false
        case nil:
            message = "\(name) stopped: its process is gone."
            crashed = false
        }
        hint = app.appID.map { "offsider app launch --restart --app \($0) --device \(device.rawValue)" }
            ?? "offsider describe-ui --summary --device \(device.rawValue)"
    }
}

extension AppExitError: OffsiderFailure {
    public var reason: FailureReason { crashed ? .appCrashed : .appStopped }
    public var failureMessage: String { message }
}

/// Asks whether the app a command began on stopped, only once a later read shows another app; a read of the same app costs nothing.
@MainActor
public struct AppExitCheck {
    public let reader: any AppLivenessReading
    public let device: DeviceID
    /// When the command began: only crash reports written since count.
    public let since: Date
    public var sleep: @MainActor (Duration) async throws -> Void

    public init(reader: any AppLivenessReading, device: DeviceID, since: Date = Date(), sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.reader = reader
        self.device = device
        self.since = since
        self.sleep = sleep
    }

    /// The app `tree` shows, with its id where the backend can name it.
    public func app(in tree: UITree?) -> ShownApp? {
        tree.flatMap { reader.shownApp(in: $0) }
    }

    /// Throws when `latest` shows another app than `first`, or none, and `first`'s process is gone on two reads 1 s apart; a running app changes nothing.
    public func check(_ first: ShownApp?, latest: UITree?) async throws {
        guard let first, first.differs(from: latest.flatMap(ShownApp.of)) else { return }
        let id = first.appID ?? ""
        let seen = first.pid.map { AppProcess(pid: $0) }
        func read() async -> AppLiveness {
            await reader.appLiveness(id, seen: seen, tree: latest, mayList: false, on: device)
        }
        guard case .notRunning = await read() else { return }
        try await sleep(.seconds(AppLivenessWatch.confirmAfter))
        guard case .notRunning = await read() else { return }
        let report: AppCrashReport?
        if let seen {
            report = await reader.crashReport(id, process: seen, since: since, on: device)
        } else {
            report = await reader.crashReport(id, since: since, on: device)
        }
        throw AppExitError(first, report: report, device: device)
    }
}
