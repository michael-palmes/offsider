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

        /// Labels the item has in the Expo dev menu and in React Native's, exact after trimming.
        public var labels: [String] {
            switch self {
            case .reload: return ["Reload"]
            case .home: return ["Go home", "Go Home", "Go to home"]
            case .inspector: return ["Element inspector", "Toggle element inspector", "Show Element Inspector", "Hide Element Inspector", "Toggle Inspector"]
            case .perfMonitor: return ["Performance monitor", "Toggle performance monitor", "Show Perf Monitor", "Hide Perf Monitor", "Perf Monitor"]
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

    /// The open menu: a Reload item beside a Go home or close control; nil when no menu shows.
    public static func read(_ tree: UITree) -> State? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        let known = Set(Item.allCases.flatMap(\.labels))
        func label(_ node: UINode) -> String? { node.label?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let hasReload = nodes.contains { label($0) == "Reload" }
        let hasHome = nodes.contains { Item.home.labels.contains(label($0) ?? "") }
        let hasClose = nodes.contains { $0.id == "xmark" || Item.close.labels.contains(label($0) ?? "") }
        guard hasReload, hasHome || hasClose else { return nil }
        var seen = Set<String>()
        let items = nodes.compactMap { node -> Entry? in
            guard let text = label(node), known.contains(text), seen.insert(text).inserted else { return nil }
            return Entry(label: text, role: node.role, frame: node.frame)
        }
        return State(menu: hasHome ? "expo" : "react-native", items: items)
    }

    /// The node for `item`, or for an exact `label`; the close control also by its `xmark` id.
    public static func node(for item: Item?, label: String?, in tree: UITree) -> UINode? {
        let nodes = tree.roots.flatMap { $0.flattened() }.filter { $0.frame != nil }
        let wanted = label.map { [$0] } ?? item?.labels ?? []
        if item == .close, let xmark = nodes.first(where: { $0.id == "xmark" }) {
            return xmark
        }
        for text in wanted {
            let matches = nodes.filter { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) == text }
            if let actionable = matches.first(where: { $0.role.isActionable || $0.role == .switch }) ?? matches.first {
                return actionable
            }
        }
        return nil
    }

    /// Which developer tools show: the element inspector's panel (its Inspect and Touchables tabs) and the performance monitor (`UI` and `JS` frame rates).
    public static func tools(in tree: UITree) -> (inspector: Bool, perfMonitor: Bool) {
        let texts = tree.roots.flatMap { $0.flattened() }.flatMap { [$0.label, $0.value] }.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let inspector = texts.contains("Inspect") && texts.contains("Touchables")
        let perf = texts.contains { $0.range(of: #"^(UI|JS)[: ]+[0-9.]+ ?fps"#, options: [.regularExpression, .caseInsensitive]) != nil }
        return (inspector, perf)
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
