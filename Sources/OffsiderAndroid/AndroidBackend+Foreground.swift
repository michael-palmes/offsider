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

    /// On a USB phone only: refuses when a browser, a system app or an app outside the allowance is in front.
    /// Reads and captures share one `dumpsys` a second; each input step reads it afresh and leaves nothing cached, since the input may open another app.
    func requireDrivableForeground(_ serial: String) async throws {
        guard DeviceID(rawValue: serial, platform: .android).isPhysicalAndroidDevice else { return }
        let package: String?
        if !AndroidForegroundCheck.beforeInput, let cached = foregroundChecks[serial], ContinuousClock.now - cached.at < Self.foregroundCheckLifetime {
            package = cached.package
        } else {
            let id = DeviceID(rawValue: serial, platform: .android)
            let top = AndroidForegroundCheck.beforeInput
                ? try await host.timing.measure(.foregroundRecheck) { try await foreground(on: id).top }
                : try await foreground(on: id).top
            package = top.flatMap { $0.split(separator: "/").first.map(String.init) }
            foregroundChecks[serial] = AndroidForegroundCheck.beforeInput ? nil : (ContinuousClock.now, package)
        }
        guard let package else { throw AndroidError.foregroundUnknown(serial) }
        try requireDrivable(package, on: serial)
    }

    /// The deny-list, then the allowance's scope, for one package on a phone.
    func requireDrivable(_ package: String, on serial: String) throws {
        if let refusal = SystemAppDenyList.refusal(package, platform: .android) {
            throw AndroidError.appNotAllowed(serial, refusal: refusal)
        }
        guard let scope = appScopes[serial] else { return }
        if let ceiling = scope.managedCeiling, !ceiling.contains(package) {
            throw AndroidError.appNotPermitted(serial, package: package, byManagedPolicy: true)
        }
        if scope.needsTarget, scope.target == nil {
            throw AndroidError(
                .appNotAllowed,
                "\(serial) is allowed for any app, so each command names the app it drives, and none was named. Offsider did nothing. "
                    + "Name it in offsider.login.json's package, pass --app <package>, or pin one app with `offsider device-access allow`.",
                hint: "offsider device-access allow"
            )
        }
        if !scope.needsTarget, !scope.permitted.contains(package) {
            throw AndroidError.appNotPermitted(serial, package: package, byManagedPolicy: false)
        }
        if let target = scope.target, package != target {
            throw AndroidError(
                .appNotAllowed,
                "\(package) is in front on \(serial), not \(target), the app this command drives, so Offsider did nothing. Bring \(target) to the front, then retry."
            )
        }
    }

    /// On a phone, the active window from a tree read must belong to a drivable app: the notification shade or quick settings over an allowed app is refused.
    /// Uses the windows the helper listed, else the uiautomator root's package; adds no device read.
    func requireDrivableWindows(_ tree: UITree, on serial: String) throws {
        guard DeviceID(rawValue: serial, platform: .android).isPhysicalAndroidDevice else { return }
        for package in Self.activeWindowPackages(tree) {
            try requireDrivable(package, on: serial)
        }
    }

    /// The packages of the windows that hold focus, keyboards aside; the `application` roots' packages when the source listed no windows.
    static func activeWindowPackages(_ tree: UITree) -> [String] {
        if let windows = tree.windows, !windows.isEmpty {
            let active = windows.filter { ($0.active || $0.focused) && $0.kind != "inputMethod" }.compactMap(\.package)
            if !active.isEmpty { return Array(Set(active)).sorted() }
        }
        let roots = tree.roots.filter { $0.role == .application }.compactMap { node -> String? in
            guard case .android(let native) = node.native else { return nil }
            return native.package
        }
        return Array(Set(roots)).sorted()
    }

    /// The app `--app` or offsider.login.json names for this command on a phone; the foreground checks then require exactly it.
    /// False when the device has no allowance scope or already targets that app.
    @discardableResult
    public func selectApp(_ package: String, on serial: String) -> Bool {
        guard var scope = appScopes[serial], scope.target != package else { return false }
        scope.target = package
        appScopes[serial] = scope
        return true
    }
}

/// Set by an input session around its foreground check, so every input step on a phone reads the front app again.
enum AndroidForegroundCheck {
    @TaskLocal static var beforeInput = false
}

/// The apps a phone's allowance permits, already narrowed by any managed `allowedBundleIDs` ceiling.
public struct AndroidAppScope: Equatable, Sendable {
    public let permitted: Set<String>
    public let managedCeiling: Set<String>?
    /// True for a phone allowed for any app: each command names its one app.
    public let needsTarget: Bool
    /// The one app this command drives; any other app in front is refused.
    public var target: String?

    public init(permitted: Set<String>, managedCeiling: Set<String>?, needsTarget: Bool = false, target: String? = nil) {
        self.permitted = permitted
        self.managedCeiling = managedCeiling
        self.needsTarget = needsTarget
        self.target = target
    }
}
