import Foundation

/// Where typed text would go, as a tree shows it.
public enum TextFocus: Equatable, Sendable {
    /// A text field on the front screen has input focus.
    case field(UINode)
    /// A software keyboard shows on iOS, so a field has focus, though the tree does not say which.
    case keyboard
    /// Android reports input focus exactly, so a keyboard up with no listed field focused means the field is hidden from accessibility,
    /// as an app's own keypad often hides its field and keeps whatever keys reach it out of its state.
    case unlisted
    /// Input focus is on something that takes no text, such as a button that opened an app's own keypad.
    case notEditable(UINode)
    /// Nothing has input focus and no keyboard shows.
    case none

    /// Text typed now reaches a field.
    public var takesText: Bool {
        switch self {
        case .field, .keyboard: return true
        case .unlisted, .notEditable, .none: return false
        }
    }

    /// Focus on a screen beneath the front one is left over from before it was covered, and the keyboard's own fields are not the app's.
    public static func read(_ tree: UITree) -> TextFocus {
        let appRoots = tree.roots.filter { $0.role != .keyboard }
        let stack = ScreenStack.build(roots: appRoots, viewport: tree.viewport)
        var focused: [UINode] = []
        func walk(_ node: UINode) {
            guard node.role != .keyboard else { return }
            if node.state.focused == true, !stack.isBeneath(node, in: appRoots) { focused.append(node) }
            node.children.forEach(walk)
        }
        appRoots.forEach(walk)
        if let field = focused.last(where: { $0.role.isTextInput }) {
            return .field(field)
        }
        let keyboard = hasKeyboard(tree)
        // iOS may name a web view, not the input inside it, as focused while its keyboard is up.
        if keyboard, tree.platform == .ios {
            return .keyboard
        }
        if let other = focused.last {
            return .notEditable(other)
        }
        return keyboard ? .unlisted : .none
    }

    /// A keyboard on screen, or one whose frame the tree cannot place.
    static func hasKeyboard(_ tree: UITree) -> Bool {
        let keyboards = tree.roots.flatMap { $0.flattened() }.filter { $0.role == .keyboard }
        guard let viewport = tree.viewport else { return !keyboards.isEmpty }
        return keyboards.contains { keyboard in
            guard let frame = keyboard.frame, frame.width > 0, frame.height > 0 else { return false }
            return frame.isVisible(in: viewport)
        }
    }
}
