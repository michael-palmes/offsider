import Foundation

/// The bar iOS draws beside the keys (suggestions, AutoFill, a hardware keyboard's shortcuts): its text is hidden where iOS trees are mapped, and its frame painted in screenshots.
public enum KeyboardBar {
    /// `SystemInputAssistantView`, as an iOS 27 simulator's tree and the XCUITest runner's snapshot both list it.
    public static let idPrefix = "SystemInputAssistant"
    /// The keyboard's whole area in the app's own window, bar included; an app's accessory bar sits above it.
    static let containerID = "inputView"
    /// The keyboard's area reaches about 17 pt above the keys with no bar, and 44 pt or more with one.
    static let shortestBar: Double = 30
    /// How far from the keys, or from the screen's bottom edge, a bar that is not listed can reach.
    static let band: Double = 64
    /// A hardware keyboard's bar floats this far clear of the bottom edge at most.
    static let bottomMargin: Double = 32

    public static func isBar(_ node: UINode) -> Bool {
        guard case .ios = node.native else { return false }
        return node.id?.hasPrefix(idPrefix) == true
    }

    /// The runner's Keyboard element, which spans the keys; a simulator's own tree lists none.
    static func isWholeKeyboard(_ node: UINode) -> Bool {
        node.native.typeName == "Keyboard" && !node.isAndroidNode
    }

    private static func isKey(_ node: UINode) -> Bool {
        node.native.typeName == "Key"
    }

    /// The top of a whole keyboard's first row of keys; nil when it lists none, as another app's keyboard does.
    private static func keysTop(in keyboard: UINode) -> Double? {
        keyboard.flattened().filter(isKey).compactMap(\.frame).filter { $0.height > 0 }.map(\.y).min()
    }

    private enum Scope {
        case outside
        case everything
        /// Inside a whole keyboard: what ends above this line is not a key.
        case above(Double)
    }

    /// `roots` with the text of every bar, and of whatever a whole keyboard holds above its keys (all of it when it lists no keys), reading `KeyboardText.marker`; frames, roles and ids stay.
    public static func hiding(_ roots: [UINode]) -> [UINode] {
        guard roots.contains(where: { $0.contains(where: { isBar($0) || isWholeKeyboard($0) }) }) else { return roots }
        return roots.map { hide($0, scope: .outside) }
    }

    private static func hide(_ node: UINode, scope: Scope) -> UINode {
        var scope = scope
        var copy = node
        if isBar(node) {
            scope = .everything
        } else if case .outside = scope, isWholeKeyboard(node) {
            scope = keysTop(in: node).map(Scope.above) ?? .everything
        } else if case .above(let top) = scope, !isKey(node), node.frame.map({ $0.y + $0.height <= top + 1 }) != false {
            KeyboardText.hideText(&copy)
        }
        if case .everything = scope { KeyboardText.hideText(&copy) }
        copy.children = node.children.map { hide($0, scope: scope) }
        return copy
    }

    /// A point read's answer comes with no parents, so its text is hidden when its middle lies in one of `bars`, the frames a whole read listed.
    public static func hiding(_ node: UINode, inside bars: [UIFrame]) -> UINode {
        guard let centre = node.frame?.center, bars.contains(where: { $0.contains(centre) }) else { return node }
        return hide(node, scope: .everything)
    }

    /// The frames of every bar in `roots`, at any depth, for `hiding(_:inside:)`.
    public static func frames(in roots: [UINode]) -> [UIFrame] {
        roots.flatMap { $0.flattened() }.filter(isBar).compactMap(\.frame).filter { $0.width > 0 && $0.height > 0 }
    }

    /// Where `hiding` may have hidden text: every bar and whole keyboard in `roots`, outermost only.
    static func scopes(in roots: [UINode]) -> [UINode] {
        var found: [UINode] = []
        func collect(_ node: UINode) {
            if isBar(node) || isWholeKeyboard(node) {
                found.append(node)
            } else {
                node.children.forEach(collect)
            }
        }
        roots.forEach(collect)
        return found
    }

    /// What a capture paints for the bar, and whether it had to guess where.
    public struct Placement: Equatable, Sendable {
        /// A nil frame is a bar that is on screen with nowhere to paint, which withholds the capture.
        public var frames: [UIFrame?]
        /// True when a keyboard is up and its bar is not listed, so `frames` is a band where one would be.
        public var unplaced: Bool

        public init(frames: [UIFrame?] = [], unplaced: Bool = false) {
            self.frames = frames
            self.unplaced = unplaced
        }

        public var isEmpty: Bool { frames.isEmpty }
    }

    /// The listed bars' frames; with none listed, a band where a keyboard that is up, or a text field in focus with no keys, could draw one.
    public static func placement(in tree: UITree) -> Placement {
        guard tree.platform == .ios else { return Placement() }
        let viewport = tree.viewport
        let shown = { (frame: UIFrame) in frame.width > 0 && frame.height > 0 && viewport.map(frame.isVisible(in:)) != false }
        let nodes = tree.roots.flatMap { $0.flattened() }
        let bars = nodes.filter(isBar)
        let listed = bars.compactMap(\.frame).filter(shown)
        if !listed.isEmpty { return Placement(frames: listed) }
        let unframed = bars.contains { $0.frame == nil }

        let keyboards = nodes.filter { $0.role == .keyboard && $0.frame.map(shown) == true }
        let wholes = keyboards.filter(isWholeKeyboard).compactMap(\.frame)
        let keys = keyboards.filter { !isWholeKeyboard($0) }.compactMap(\.frame)
        if keys.isEmpty, !wholes.isEmpty { return Placement(frames: wholes) }
        if let top = keys.map(\.y).min(), let span = UIFrame.union(of: keys) {
            let areas = wholes + nodes.filter { $0.id == containerID }.compactMap(\.frame).filter(shown)
            if let area = areas.min(by: { $0.y < $1.y }), !unframed {
                let reach = top - area.y
                guard reach >= shortestBar else { return Placement() }
                return Placement(frames: [UIFrame(x: area.x, y: area.y, width: area.width, height: reach)], unplaced: true)
            }
            let from = max(viewport?.y ?? 0, top - band)
            return Placement(frames: [UIFrame(x: span.x, y: from, width: span.width, height: top - from)], unplaced: true)
        }

        let focused = nodes.contains { node in
            guard node.state.focused == true, node.role.isTextInput else { return false }
            return node.frame.map(shown) != false
        }
        guard focused || unframed else { return Placement() }
        guard let viewport else { return Placement(frames: [nil], unplaced: true) }
        let height = min(viewport.height, band + bottomMargin)
        return Placement(
            frames: [UIFrame(x: viewport.x, y: viewport.y + viewport.height - height, width: viewport.width, height: height)], unplaced: true
        )
    }
}
