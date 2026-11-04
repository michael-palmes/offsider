import Foundation

/// The tree every cover check on one read judges against, read once: its index, its pages and the overlays each check looks for.
public struct CoverGround: Sendable {
    public let tree: TreeIndex
    public let viewport: UIFrame
    public let stack: ScreenStack
    /// Scroll indicators, which take no taps.
    public let indicators: [UINode]
    /// Expo's floating dev menu buttons.
    public let devMenuButtons: [UINode]
    /// LogBox toasts, in tree order.
    public let logBoxToasts: [UINode]

    public var roots: [UINode] { tree.roots }

    public init(tree: TreeIndex, viewport: UIFrame, stack: ScreenStack) {
        self.tree = tree
        self.viewport = viewport
        self.stack = stack
        indicators = ScrollIndicator.all(in: tree.roots)
        devMenuButtons = KnownOverlays.devMenuButtons(in: tree.roots, viewport: viewport)
        logBoxToasts = tree.nodes.filter { KnownOverlays.logBoxToast($0, viewport: viewport) != nil }
    }

    public init(roots: [UINode], viewport: UIFrame, stack: ScreenStack) {
        self.init(tree: TreeIndex(roots: roots), viewport: viewport, stack: stack)
    }
}
