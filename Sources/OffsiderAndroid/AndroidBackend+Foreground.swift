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
        let free = appScopes[serial].map { $0.wholeDevice && $0.target == nil } ?? false
        guard DeviceID(rawValue: serial, platform: .android).isPhysicalAndroidDevice, !free else { return }
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

    /// What no app in front can change first (an app this phone may not drive named, or none named), then the deny-list and the allowance's scope for one package on a phone.
    func requireDrivable(_ package: String, on serial: String) throws {
        let scope = appScopes[serial]
        if let scope, scope.wholeDevice {
            // A named app still holds its command to it, so a login's keys never reach what comes up over it.
            if let target = scope.target, package != target { throw Self.otherThanTarget(package, target, on: serial) }
            return
        }
        if let scope { try requireDrivableTarget(of: scope, on: serial) }
        if SystemAppDenyList.isPermissionDialog(package, platform: .android) {
            throw AndroidError.permissionDialogInFront(serial, app: scope?.target ?? scope?.permitted.onlyElement)
        }
        if let refusal = SystemAppDenyList.refusal(package, platform: .android) {
            throw AndroidError.otherAppRefused(serial, refusal: refusal)
        }
        guard let scope else { return }
        if let ceiling = scope.managedCeiling, !ceiling.contains(package) {
            throw AndroidError.otherAppNotPermitted(serial, package: package, byManagedPolicy: true)
        }
        if !scope.needsTarget, !scope.permitted.contains(package) {
            throw AndroidError.otherAppNotPermitted(serial, package: package, byManagedPolicy: false)
        }
        if let target = scope.target, package != target { throw Self.otherThanTarget(package, target, on: serial) }
    }

    private static func otherThanTarget(_ package: String, _ target: String, on serial: String) -> AndroidError {
        AndroidError(
            .otherAppInFront,
            "\(package) is in front on \(serial), not \(target), the app this command drives, so Offsider did nothing. Bring \(target) to the front, then retry."
        )
    }

    /// `login` on a test device holds to the app it signs in to, as a named app does; no other scope changes, since they already check.
    public func holdToApp(_ package: String, on serial: String) {
        guard appScopes[serial]?.wholeDevice == true else { return }
        appScopes[serial]?.target = package
    }

    /// The refusals that stand whichever app is in front, so a wait need not sit them out.
    private func requireDrivableTarget(of scope: AndroidAppScope, on serial: String) throws {
        guard let target = scope.target else {
            guard scope.needsTarget else { return }
            throw AndroidError(
                .appNotAllowed,
                "\(serial) is allowed for any app, so each command names the app it drives, and none was named. Offsider did nothing. "
                    + "Name it in offsider.login.json's package, pass --app <package>, or pin one app with `offsider devices add`.",
                hint: "offsider devices add"
            )
        }
        if let refusal = SystemAppDenyList.refusal(target, platform: .android) {
            throw AndroidError.appNotAllowed(serial, refusal: refusal)
        }
        if let ceiling = scope.managedCeiling, !ceiling.contains(target) {
            throw AndroidError.appNotPermitted(serial, package: target, byManagedPolicy: true)
        }
        if !scope.needsTarget, !scope.permitted.contains(target) {
            throw AndroidError.appNotPermitted(serial, package: target, byManagedPolicy: false)
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

extension AndroidBackend: AppTargetSelecting {
    @discardableResult
    public func selectApp(_ appID: String, on id: DeviceID) -> Bool {
        selectApp(appID, on: id.rawValue)
    }

    public func selectedApp(on id: DeviceID) -> String? {
        appScopes[id.rawValue]?.target
    }
}

private extension Set {
    var onlyElement: Element? { count == 1 ? first : nil }
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
    /// A test device: every app, the launcher and system windows, with no front-app check.
    public let wholeDevice: Bool

    public init(permitted: Set<String>, managedCeiling: Set<String>?, needsTarget: Bool = false, target: String? = nil, wholeDevice: Bool = false) {
        self.permitted = permitted
        self.managedCeiling = managedCeiling
        self.needsTarget = needsTarget
        self.target = target
        self.wholeDevice = wholeDevice
    }
}
