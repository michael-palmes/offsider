import Foundation

/// Optional capability: opening a React Native debug build's dev menu, by shake on an iOS simulator and the menu key on Android.
@MainActor
public protocol ReactNativeDevMenuOpening: DeviceBackend {
    func openDevMenu(_ id: DeviceID) async throws
}

/// The Expo dev menu and React Native's own, read from the tree by their item labels.
public enum DevMenu {
    public enum Item: String, CaseIterable, Sendable {
        case reload
        case home
        case inspector
        case perfMonitor = "perf-monitor"
        case fastRefresh = "fast-refresh"
        case debugger
        case close

        /// Labels the item has in the Expo dev menu and in React Native's, exact after trimming. On Android the Expo
        /// menu's buttons read "<icon> <label>", such as "Home Go home", so a button also matches on a trailing label.
        public var labels: [String] {
            switch self {
            case .reload: return ["Reload"]
            case .home: return ["Go home", "Go Home", "Go to home"]
            case .inspector: return ["Toggle element inspector", "Toggle Element Inspector", "Element inspector", "Show Element Inspector", "Hide Element Inspector", "Toggle Inspector"]
            case .perfMonitor: return ["Toggle performance monitor", "Performance monitor", "Show Perf Monitor", "Hide Perf Monitor", "Perf Monitor"]
            case .fastRefresh: return ["Fast refresh", "Fast Refresh", "Enable Fast Refresh", "Disable Fast Refresh"]
            case .debugger: return ["Open JS debugger", "Open DevTools", "Open React Native DevTools", "Open Debugger"]
            case .close: return ["Close", "Cancel", "Dismiss"]
            }
        }

        /// Items that switch something and may leave the menu open.
        public var isToggle: Bool {
            [.inspector, .perfMonitor, .fastRefresh].contains(self)
        }
    }

    public struct Entry: Equatable, Sendable {
        public var label: String
        public var role: UIRole
        public var frame: UIFrame?
    }

    public struct State: Equatable, Sendable {
        /// `expo` when the menu has Expo's Go home, else `react-native`.
        public var menu: String
        public var items: [Entry]
    }

    /// The title React Native's own dev menu shows on Android, which has no close control.
    static let reactNativeTitle = "React Native Dev Menu"

    /// The open menu: a Reload item beside a Go home or close control, or under React Native's title; nil when no menu shows.
    public static func read(_ tree: UITree) -> State? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        let titled = nodes.contains { trimmedLabel($0) == reactNativeTitle }
        let hasReload = nodes.contains { matchedLabel($0, Item.reload.labels) != nil }
        let hasHome = nodes.contains { matchedLabel($0, Item.home.labels) != nil }
        let hasClose = nodes.contains { $0.id == "xmark" || matchedLabel($0, Item.close.labels) != nil }
        guard hasReload, hasHome || hasClose || titled else { return nil }
        let items = Item.allCases.compactMap { item -> (Int, Entry)? in
            guard let (index, node, text) = best(item.labels, in: nodes) else { return nil }
            return (index, Entry(label: text, role: node.role, frame: node.frame))
        }
        return State(menu: hasHome ? "expo" : "react-native", items: items.sorted { $0.0 < $1.0 }.map(\.1))
    }

    /// The node for `item`, or for an exact `label`; the close control also by its `xmark` id.
    public static func node(for item: Item?, label: String?, in tree: UITree) -> UINode? {
        let nodes = tree.roots.flatMap { $0.flattened() }.filter { $0.frame != nil }
        if item == .close, let xmark = nodes.first(where: { $0.id == "xmark" }) {
            return xmark
        }
        let wanted = label.map { [$0] } ?? item?.labels ?? []
        return best(wanted, in: nodes)?.node
    }

    /// The first actionable node carrying one of `labels`, else the first node at all, with its pre-order index and the label it matched.
    private static func best(_ labels: [String], in nodes: [UINode]) -> (index: Int, node: UINode, label: String)? {
        let matches = nodes.enumerated().compactMap { index, node in matchedLabel(node, labels).map { (index, node, $0) } }
        return matches.first { $0.1.role.isActionable || $0.1.role == .switch } ?? matches.first
    }

    /// The label of `labels` the node shows: its whole label, or for a button the end of "<icon> <label>".
    static func matchedLabel(_ node: UINode, _ labels: [String]) -> String? {
        guard let text = trimmedLabel(node) else { return nil }
        if let exact = labels.first(where: { $0 == text }) { return exact }
        guard node.role.isActionable else { return nil }
        return labels.first { text.hasSuffix(" " + $0) }
    }

    private static func trimmedLabel(_ node: UINode) -> String? {
        node.label?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which developer tools show: the element inspector's panel (its Inspect and Touchables tabs) and the performance monitor (`UI` and `JS` frame rates, which iOS draws as a `RAM` cell beside `UI` and `JS` columns).
    public static func tools(in tree: UITree) -> (inspector: Bool, perfMonitor: Bool) {
        let texts = tree.roots.flatMap { $0.flattened() }.flatMap { [$0.label, $0.value] }.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let inspector = texts.contains("Inspect") && texts.contains("Touchables")
        let fps = texts.contains { $0.range(of: #"^(UI|JS)[: ]+[0-9.]+ ?fps"#, options: [.regularExpression, .caseInsensitive]) != nil }
        let columns = texts.contains("UI") && texts.contains("JS") && texts.contains { $0.range(of: #"^RAM [0-9.]+ ?MB$"#, options: .regularExpression) != nil }
        return (inspector, fps || columns)
    }

    public static func jsonLine(_ state: State) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("menu", .string(state.menu)),
            ("items", .array(state.items.map { .object([("label", .string($0.label)), ("role", .string($0.role.rawValue))]) })),
        ]).rendered(compact: true)
    }

    public static func toolsJSONLine(inspector: String, perfMonitor: String) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("inspector", .string(inspector)),
            ("perfMonitor", .string(perfMonitor)),
        ]).rendered(compact: true)
    }
}
