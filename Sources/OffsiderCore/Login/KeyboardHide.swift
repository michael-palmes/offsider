import Foundation

/// What `keyboard hide` may send for one screen: the keyboard's own way out, never Return, which can submit a form.
public enum KeyboardHide {
    public enum Step: Equatable, Sendable {
        /// No keyboard is on screen, or on Android no docked keys, where Back would go to the app.
        case absent
        /// Android: Back, which hides docked keys and never reaches the app.
        case back
        /// iOS: the hide key, or Done in the bar on top of the keys.
        case control(UIPoint)
        /// A keyboard with no way out of its own, as an iPhone's has without an app's Done bar.
        case noWayOut
    }

    public static func isUp(_ tree: UITree) -> Bool {
        tree.platform == .android ? KeyboardDismiss.docksKeys(in: tree) : UITreeContext.showsKeyboard(tree)
    }

    public static func step(in tree: UITree) -> Step {
        guard isUp(tree) else { return .absent }
        if tree.platform == .android { return .back }
        return KeyboardDismiss.closingControl(in: tree).map(Step.control) ?? .noWayOut
    }

    /// The next spot `--tap-outside` tries: empty space clear of every text field, of the keys and of `tried`.
    public static func outsidePoint(in tree: UITree, tried: [UIPoint]) -> UIPoint? {
        let fields = tree.roots.flatMap { $0.flattened() }.filter(\.role.isTextInput).compactMap(\.frame)
        return KeyboardDismiss.points(in: tree, fields: fields, tried: tried, limit: 1).first
    }
}
