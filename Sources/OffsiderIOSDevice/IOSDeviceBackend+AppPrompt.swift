import Foundation
import OffsiderCore

extension IOSDeviceBackend: AppPromptReading, AppPromptAnswering {
    static let springBoard = "com.apple.springboard"
    /// How long a look-only read may use a prompt it proved is the named app's.
    static let promptReadLifetime: TimeInterval = 5

    public func appPrompt(for app: String, on id: DeviceID) async throws -> (prompt: AppPrompt, tree: UITree) {
        try requirePromptDevice(id)
        let read = try await promptRead(app, on: id)
        return (read.prompt, read.tree)
    }

    /// Read whole again: the same title, buttons and frames, or the prompt changed.
    public func stillInFront(_ prompt: AppPrompt, on id: DeviceID) async throws -> Bool {
        (try? await promptRead(prompt.app, on: id))?.prompt == prompt
    }

    /// One runner call that checks the alert's title and the button's frame again before it taps, so the tap cannot land on a prompt that took its place.
    public func answer(_ prompt: AppPrompt, with button: AppPrompt.Button, on id: DeviceID) async throws {
        try requirePromptDevice(id)
        try await requireWired(id)
        let client = try await runner(for: id)
        defer { forgetPinConfirmation(id) }
        try await host.timing.measure("alert-tap") { try await client.tapAlert(app: prompt.app, title: prompt.title, label: button.label, frame: button.frame) }
    }

    /// A phone in personal use never has a prompt read or answered, whichever command asks.
    func requirePromptDevice(_ id: DeviceID) throws {
        guard state.pinPolicy != nil, !state.drivesWhole else { return }
        throw IOSDeviceError(
            .appNotAllowed,
            "\(id.rawValue) is in personal use, not a test device, so Offsider reads and answers no system prompt on it. The prompt is the user's to answer."
        )
    }

    /// SpringBoard's alert when it is a permission prompt over `app`: the app's process is in the foreground beneath it, no other app is active, and the title names the app first.
    func promptRead(_ app: String, on id: DeviceID) async throws -> (prompt: AppPrompt, tree: UITree, alert: Data) {
        if state.drivesWhole { try await prepareWholeDevice(id) }
        let client = try await runner(for: id)
        let read = try await host.timing.measure("alert") { try await client.alert(app: app) }
        if read.locked { throw IOSDeviceError.screenLocked(id.rawValue) }
        if let hosted = read.hosted { throw AppPromptRefusal.notPermission(what: "\(hosted), which iOS draws in a process of its own") }
        let others = (read.active ?? []).filter { $0 != Self.springBoard && $0 != app }
        guard let data = read.alert else { throw AppPromptRefusal.notShown(front: read.appInFront ? app : others.first) }
        let parsed = try Self.tree(fromSnapshot: data, device: id.rawValue)
        guard let alert = parsed.roots.first else { throw AppPromptRefusal.unreadable(why: "the runner sent an empty alert") }
        let title = TerminalText.quoted(SelectorText.truncated(alert.normalizedLabel ?? "", limit: 120))
        guard read.appInFront else {
            throw AppPromptRefusal.otherApp(requester: others.first, why: "\(app) is not the app beneath the alert \(title)")
        }
        if let other = others.first {
            throw AppPromptRefusal.otherApp(requester: other, why: "the alert \(title) is over \(other)")
        }
        let prompt = try IOSPermissionAlert.read(alert: alert, app: app, appName: try await appName(app, on: id))
        let root = UINode(role: .application, label: "SpringBoard", native: .ios(IOSNativeAttributes(type: "Application")), children: [alert])
        return (prompt, UITree(platform: .ios, device: id.rawValue, roots: [root]), data)
    }

    /// The app's display name, which a permission prompt's title quotes; read once per command.
    private func appName(_ app: String, on id: DeviceID) async throws -> String? {
        let key = "\(id.rawValue) \(app)"
        if let known = state.appNames[key] { return known }
        let name = try await appInfo(app, on: id).name
        state.appNames[key] = name
        return name
    }

    /// The prompt a look-only read proved is the named app's, while it is fresh; input never sees it.
    func provenPrompt(_ id: DeviceID) -> (prompt: AppPrompt, alert: Data)? {
        guard PhoneRead.overSystemWindow, let proven = state.provenPrompts[id.rawValue], Date().timeIntervalSince(proven.at) < Self.promptReadLifetime else { return nil }
        return (proven.prompt, proven.alert)
    }

    /// SpringBoard's root holding the proven alert, in the runner's snapshot JSON, for a look-only read in the app's place.
    static func promptSnapshot(_ alert: Data) throws -> Data {
        guard let nodes = try JSONSerialization.jsonObject(with: alert) as? [[String: Any]] else {
            throw IOSDeviceError(.runnerFailed, "The runner sent an alert Offsider could not read.")
        }
        return try JSONSerialization.data(withJSONObject: [["type": "Application", "AXLabel": "SpringBoard", "children": nodes] as [String: Any]])
    }
}

extension IOSDeviceBackend: AppPromptCapturing {
    public func promptOverSelectedApp(on id: DeviceID) async throws -> AppPrompt? {
        guard PhoneRead.overSystemWindow, state.pinPolicy != nil, state.drivesWhole, let app = targetApp else { return nil }
        state.provenPrompts[id.rawValue] = nil
        guard let read = try? await promptRead(app, on: id) else { return nil }
        state.provenPrompts[id.rawValue] = (Date(), read.prompt, read.alert)
        return read.prompt
    }
}

extension IOSDeviceBackend: SystemWindowReporting {
    public func systemWindow(for id: DeviceID) -> UITreeContext.Window? {
        guard let proven = state.provenPrompts[id.rawValue], Date().timeIntervalSince(proven.at) < Self.promptReadLifetime else { return nil }
        return proven.prompt.window
    }
}
