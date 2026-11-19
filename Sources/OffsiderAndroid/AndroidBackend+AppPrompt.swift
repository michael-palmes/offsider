import Foundation
import OffsiderCore

extension AndroidBackend: AppPromptReading {
    public func appPrompt(for app: String, on id: DeviceID) async throws -> (prompt: AppPrompt, tree: UITree) {
        let serial = id.rawValue
        try requirePromptDevice(serial)
        try await prepare()
        let owner = try await promptOwner(of: app, on: serial)
        let tree = try await accessibilityTree(for: id)
        guard let prompt = AndroidPermissionPrompt.read(tree, app: app, token: owner.token) else {
            // The dialog left between the two reads, or this build lays it out with ids Offsider does not know.
            throw AndroidPermissionPrompt.isDialog(tree)
                ? AppPromptRefusal.unreadable(why: "none of its buttons carries a permission button id")
                : AppPromptRefusal.notShown(front: nil)
        }
        return (prompt, tree)
    }

    public func stillInFront(_ prompt: AppPrompt, on id: DeviceID) async throws -> Bool {
        try requirePromptDevice(id.rawValue)
        return (try? await promptOwner(of: prompt.app, on: id.rawValue))?.token == prompt.token
    }

    /// The resumed activity when it is the permission dialog `app` raised; throws what is in front otherwise. The app's uid is read once per command.
    private func promptOwner(of app: String, on serial: String) async throws -> AndroidPromptOwner {
        let package = try ExpoDevClient.validate(appID: app)
        let key = "\(serial) \(package)"
        let script = appUIDs[key] == nil ? AndroidPromptOwner.readScript(app: package) : AndroidPromptOwner.ownerScript
        let result = try await requireClient().shell(script, on: serial, timeout: .seconds(5), label: "dumpsys activity activities")
        let read = AndroidPromptOwner.parse(result.stdoutText)
        if let uid = read.appUID { appUIDs[key] = uid }
        guard let owner = read.owner else { throw AppPromptRefusal.notShown(front: nil) }
        if let refusal = owner.refusal(for: package, appUID: appUIDs[key]) { throw refusal }
        return owner
    }

    /// A phone in personal use never has a prompt read or answered, whichever command asks.
    private func requirePromptDevice(_ serial: String) throws {
        guard DeviceID(rawValue: serial, platform: .android).isPhysicalAndroidDevice, appScopes[serial]?.wholeDevice != true else { return }
        throw AndroidError.permissionDialogInFront(serial, app: appScopes[serial]?.target)
    }
}

extension AndroidBackend: AppPromptCapturing {
    static let promptReadLifetime: Duration = .seconds(5)

    public func promptOverSelectedApp(on id: DeviceID) async throws -> AppPrompt? {
        let serial = id.rawValue
        guard PhoneRead.overSystemWindow, id.isPhysicalAndroidDevice, let scope = appScopes[serial], scope.wholeDevice, let target = scope.target else { return nil }
        try await prepare()
        // The front-app check this read would make anyway, kept for it, so an app in front pays nothing more.
        let package = try await foreground(on: id).top.flatMap { $0.split(separator: "/").first.map(String.init) }
        foregroundChecks[serial] = (ContinuousClock.now, package)
        guard let package, SystemAppDenyList.isPermissionDialog(package, platform: .android),
              let owner = try? await promptOwner(of: target, on: serial) else { return nil }
        // The proof lets this one tree read through; it stays only when that read finds the prompt.
        promptReads[serial] = (ContinuousClock.now, package, UITreeContext.Window(title: nil, kind: .system, package: package, readOnly: true))
        guard let tree = try? await accessibilityTree(for: id), let prompt = AndroidPermissionPrompt.read(tree, app: target, token: owner.token) else {
            promptReads[serial] = nil
            return nil
        }
        promptReads[serial] = (ContinuousClock.now, package, prompt.window)
        return prompt
    }

    /// The permission dialog a read that only looks proved belongs to the named app, for five seconds, long enough for one capture; input never sees it.
    func provenPrompt(_ serial: String, package: String) -> UITreeContext.Window? {
        guard PhoneRead.overSystemWindow, !AndroidForegroundCheck.beforeInput, let proven = promptReads[serial], proven.package == package,
              ContinuousClock.now - proven.at < Self.promptReadLifetime else { return nil }
        return proven.window
    }
}
