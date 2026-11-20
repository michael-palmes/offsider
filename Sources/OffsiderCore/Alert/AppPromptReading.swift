import Foundation

/// A backend that can tell a permission or consent prompt in front belongs to one app, and read it.
@MainActor
public protocol AppPromptReading: DeviceBackend {
    /// The prompt in front that `app` raised and the tree it was read from; throws `AppPromptRefusal` when nothing in front can be tied to the app.
    func appPrompt(for app: String, on id: DeviceID) async throws -> (prompt: AppPrompt, tree: UITree)
    /// True while `prompt` still holds the screen for its app; asked just before it is answered.
    func stillInFront(_ prompt: AppPrompt, on id: DeviceID) async throws -> Bool
}

/// A backend that answers a prompt by its button in one step that checks the prompt is still the one read.
@MainActor
public protocol AppPromptAnswering: AppPromptReading {
    func answer(_ prompt: AppPrompt, with button: AppPrompt.Button, on id: DeviceID) async throws
}

/// A backend that holds a device's reads to one named app, and can prove a permission prompt in front belongs to that app.
@MainActor
public protocol AppPromptCapturing: AnyObject {
    /// On a test device held to a named app, the prompt in front that the app raised, which `describe-ui` and `screenshot` may then read for a moment; nil everywhere else. Input never passes.
    func promptOverSelectedApp(on id: DeviceID) async throws -> AppPrompt?
}

extension AppPrompt {
    /// Everything on a `screen` outside the prompt's box, as up to four regions a capture paints.
    public func outside(on screen: UIFrame) -> [PointRegion] {
        let box = frame.intersection(screen) ?? frame
        let bands = [
            PointRegion(x: screen.x, y: screen.y, width: screen.width, height: box.y - screen.y),
            PointRegion(x: screen.x, y: box.y + box.height, width: screen.width, height: screen.y + screen.height - box.y - box.height),
            PointRegion(x: screen.x, y: box.y, width: box.x - screen.x, height: box.height),
            PointRegion(x: box.x + box.width, y: box.y, width: screen.x + screen.width - box.x - box.width, height: box.height),
        ]
        return bands.filter { $0.width >= 1 && $0.height >= 1 }
    }

    /// The window a read-only capture names: the prompt's title and what draws it.
    public var window: UITreeContext.Window {
        UITreeContext.Window(title: title, kind: .system, package: source, readOnly: true)
    }
}
