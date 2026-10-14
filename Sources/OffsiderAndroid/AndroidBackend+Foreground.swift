import Foundation
import OffsiderCore

extension AndroidBackend: ForegroundReading {
    public func foreground(on id: DeviceID) async throws -> ForegroundActivities {
        try await prepare()
        let result = try await requireClient().shell(AndroidForeground.readScript, on: id.rawValue, timeout: .seconds(5), label: "dumpsys activity activities; cmd package resolve-activity")
        return AndroidForeground.parse(result.stdoutText)
    }

    public func startHomeIntent(on id: DeviceID) async throws {
        _ = try await settingsShell(AndroidForeground.homeIntent, on: id.rawValue)
    }
}

extension AndroidBackend {
    static let foregroundCheckLifetime: Duration = .seconds(1)

    /// On a USB phone only: refuses when a browser, a system app or an unknown app is in front. One `dumpsys` a second at most.
    func requireDrivableForeground(_ serial: String) async throws {
        guard DeviceID(rawValue: serial, platform: .android).isPhysicalAndroidDevice else { return }
        let package: String?
        if let cached = foregroundChecks[serial], ContinuousClock.now - cached.at < Self.foregroundCheckLifetime {
            package = cached.package
        } else {
            let top = try await foreground(on: DeviceID(rawValue: serial, platform: .android)).top
            package = top.flatMap { $0.split(separator: "/").first.map(String.init) }
            foregroundChecks[serial] = (ContinuousClock.now, package)
        }
        guard let package else { throw AndroidError.foregroundUnknown(serial) }
        if let refusal = SystemAppDenyList.refusal(package, platform: .android) {
            throw AndroidError.appNotAllowed(serial, refusal: refusal)
        }
        if let scope = appScopes[serial], !scope.permitted.contains(package) {
            throw AndroidError.appNotPermitted(serial, package: package, byManagedPolicy: scope.managedCeiling.map { !$0.contains(package) } ?? false)
        }
    }
}

/// The apps a phone's allowance permits, already narrowed by any managed `allowedBundleIDs` ceiling.
public struct AndroidAppScope: Equatable, Sendable {
    public let permitted: Set<String>
    public let managedCeiling: Set<String>?

    public init(permitted: Set<String>, managedCeiling: Set<String>?) {
        self.permitted = permitted
        self.managedCeiling = managedCeiling
    }
}
