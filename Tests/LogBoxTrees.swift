import Foundation
import OffsiderCore

/// React Native LogBox screens as the trees show them; on Android the inspector and the empty dialog are untitled windows that hide the app.
enum LogBoxTrees {
    static let package = "com.example.app"

    static func toast(_ count: Int, y: Double = 806, platform: DevicePlatform = .ios) -> UINode {
        FakeUI.node(.other, label: "\(count == 1 ? "!" : String(count)), Request failed", frame: FakeUI.frame(10, y, 382, 48), platform: platform)
    }

    static func inspector(log: Int = 1, of: Int = 1, minimize: Bool = true, platform: DevicePlatform = .ios) -> [UINode] {
        let header = FakeUI.node(.text, label: "Log \(log) of \(of)", frame: FakeUI.frame(150, 60, 100, 20), platform: platform)
        let dismiss = FakeUI.node(.button, label: "Dismiss", frame: FakeUI.frame(0, 820, 200, 54), platform: platform)
        let minimizeButton = FakeUI.node(.button, label: "Minimize", frame: FakeUI.frame(202, 820, 200, 54), platform: platform)
        return minimize ? [header, dismiss, minimizeButton] : [header, dismiss]
    }

    /// The app in its titled activity window.
    static func androidApp(_ children: [UINode]) -> UITree {
        androidTree(children, title: "Playground")
    }

    /// The inspector in its own window, so the app's nodes are missing.
    static func androidInspector(log: Int = 1, of: Int = 1, minimize: Bool = true) -> UITree {
        androidTree(inspector(log: log, of: of, minimize: minimize, platform: .android), title: nil)
    }

    /// LogBox's dialog with nothing drawn in it: a screen-filling root and unlabelled groups.
    static func androidEmptyDialog() -> UITree {
        androidTree([FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), platform: .android, children: [
            FakeUI.node(.group, frame: FakeUI.frame(0, 48, 402, 802), platform: .android),
        ])], title: nil)
    }

    /// An application window over the status bar's; untitled, it is a dialog whose activity Android left out.
    static func androidTree(_ children: [UINode], title: String?) -> UITree {
        var tree = FakeUI.tree(platform: .android, label: title, children)
        tree.windows = [
            UIWindowInfo(id: 1, kind: "system", layer: 2, title: nil, active: false, focused: false, package: "com.android.systemui", bounds: FakeUI.frame(0, 0, 402, 48)),
            UIWindowInfo(id: 2, kind: "application", layer: 1, title: title, active: true, focused: true, package: package, bounds: FakeUI.frame(0, 0, 402, 874)),
        ]
        return tree
    }
}
