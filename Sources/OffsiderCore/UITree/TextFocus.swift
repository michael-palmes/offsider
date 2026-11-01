import Foundation

/// Where typed text would go, as a tree shows it.
public enum TextFocus: Equatable, Sendable {
    /// A text field on the front screen has input focus.
    case field(UINode)
    /// A software keyboard shows on iOS, so a field has focus, though the tree does not say which.
    case keyboard
    /// On Android, which reports input focus exactly, a keyboard is up for a field hidden from accessibility, as an app keypad's often is.
    case unlisted
    /// Input focus is on something that takes no text, such as a button that opened an app's own keypad.
    case notEditable(UINode)
    /// The only field with input focus sits beneath a page drawn over it, so keys would change text nobody can see.
    case beneath(UINode)
    /// Nothing has input focus and no keyboard shows.
    case none

    /// Text typed now reaches a field.
    public var takesText: Bool {
        switch self {
        case .field, .keyboard: return true
        case .unlisted, .notEditable, .beneath, .none: return false
        }
    }

    /// Focus on a screen beneath the front one is left over from before it was covered, and the keyboard's own fields are not the app's.
    public static func read(_ tree: UITree) -> TextFocus {
        let appRoots = tree.roots.filter { $0.role != .keyboard }
        let stack = ScreenStack.build(roots: appRoots, viewport: tree.viewport)
        var focused: [UINode] = []
        var covered: UINode?
        func walk(_ node: UINode) {
            guard node.role != .keyboard else { return }
            if node.state.focused == true {
                if !stack.isBeneath(node, in: appRoots) {
                    focused.append(node)
                } else if node.role.isTextInput {
                    covered = node
                }
            }
            node.children.forEach(walk)
        }
        appRoots.forEach(walk)
        // Android can mark only the web view focused while the input inside it takes the keys.
        if let field = focused.last(where: { $0.role.isTextInput || $0.isAndroidWebView }) {
            return .field(field)
        }
        if focused.isEmpty, let covered { return .beneath(covered) }
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
    public static func hasKeyboard(_ tree: UITree) -> Bool {
        let keyboards = tree.roots.flatMap { $0.flattened() }.filter { $0.role == .keyboard }
        guard let viewport = tree.viewport else { return !keyboards.isEmpty }
        return keyboards.contains { keyboard in
            guard let frame = keyboard.frame else { return true }
            return frame.width > 0 && frame.height > 0 && frame.isVisible(in: viewport)
        }
    }
}

/// Point reads for a focused field the tree leaves out: a tree can miss whole branches of a screen, so an empty read cannot prove nothing has focus.
public enum FocusSweep {
    /// Close enough that a row meets any field drawn on the screen.
    static let rowGap: Double = 28

    /// The screen's centre line, where most fields lie, then each side, for reads in rounds that stop at the first answer.
    public static func rounds(in screen: UIFrame) -> [[UIPoint]] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        let rows = stride(from: screen.y + rowGap / 2, to: screen.y + screen.height, by: rowGap)
        let column = { (share: Double) in rows.map { UIPoint(x: screen.x + screen.width * share, y: $0) } }
        return [column(0.5), column(0.2) + column(0.8)]
    }

    /// The text field with input focus in what a point read answered; a keyboard's own fields are not the app's.
    public static func focusedField(in hit: UINode) -> UINode? {
        guard hit.role != .keyboard else { return nil }
        if hit.state.focused == true, hit.role.isTextInput { return hit }
        for child in hit.children {
            if let found = focusedField(in: child) { return found }
        }
        return nil
    }
}

extension UINode {
    /// An Android `WebView`, whose page takes typed text through it.
    var isAndroidWebView: Bool {
        guard case .android(let native) = native, let name = native.className else { return false }
        return name == "WebView" || name.hasSuffix(".WebView")
    }
}
