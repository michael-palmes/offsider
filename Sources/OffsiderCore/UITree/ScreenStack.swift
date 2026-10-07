import Foundation

/// Full-screen pages over other screens: a later sibling page (Android drawing order, iOS tree order) seals an earlier one it encloses.
public struct ScreenStack: Equatable, Sendable {
    /// One page and the elements drawn on it.
    public struct Page: Equatable, Sendable {
        /// Its pre-order index over the roots, as `flattened()` lists them.
        public var index: Int
        /// Its id, else a header label on it, else its first label.
        public var name: String
        public var frame: UIFrame
        /// Pre-order indexes of the page and everything drawn on it.
        public var content: Set<Int>
    }

    /// One covered screen, as `describe-ui --summary` folds it.
    public struct Beneath: Equatable, Sendable {
        public var name: String
        /// The page drawn directly over it.
        public var under: String
        public var elements: Int
        /// Pre-order indexes of its elements.
        public var indexes: Set<Int>
    }

    public static let empty = ScreenStack(pages: [], beneath: [], topSealer: [:])

    public let pages: [Page]
    /// Covered screens, lowest first.
    public let beneath: [Beneath]
    /// Each covered element's index to the index of the topmost page over it.
    let topSealer: [Int: Int]

    /// True when the element at this pre-order index lies beneath a page.
    public func isBeneath(index: Int) -> Bool {
        topSealer[index] != nil
    }

    /// The topmost page drawn over the element at this pre-order index; nil when none is.
    public func page(over index: Int) -> Page? {
        topSealer[index].flatMap { sealer in pages.first { $0.index == sealer } }
    }

    /// The name of the screen the element is on: its covered screen, else the topmost page it is drawn on; nil off every page.
    public func screenName(of index: Int) -> String? {
        if let covered = beneath.first(where: { $0.indexes.contains(index) }) {
            return covered.name
        }
        return pages.last { $0.content.contains(index) }?.name
    }

    /// `isBeneath(index:)` for a node of `roots`; false when it is not there.
    public func isBeneath(_ node: UINode, in roots: [UINode]) -> Bool {
        Self.index(of: node, in: roots).map(isBeneath(index:)) ?? false
    }

    /// The node's pre-order index over `roots`, as `flattened()` lists them; nil when it is not there.
    public static func index(of node: UINode, in roots: [UINode]) -> Int? {
        roots.flatMap { $0.flattened() }.firstIndex { $0.isSameElement(as: node) }
    }

    /// Covers at least half the viewport, the smallest page.
    static let minimumShare = 0.5
    /// A page's frame may miss what it encloses by this much.
    static let tolerance = 1.0

    /// Reads the stack from a tree; empty without a viewport, and on Android for siblings without drawing order.
    public static func build(roots: [UINode], viewport: UIFrame?) -> ScreenStack {
        guard let viewport, viewport.width > 0, viewport.height > 0 else { return .empty }
        let flat = FlatTree(roots: roots)
        var pages: [Int: Page] = [:]
        var lowestSealer: [Int: Int] = [:]
        var topSealer: [Int: Int] = [:]
        for parent in flat.entries.indices where flat.entries[parent].children.count > 1 && !flat.isScrolledOrKeyboard(parent) {
            guard let ordered = flat.bottomFirst(flat.entries[parent].children) else { continue }
            let byDrawingOrder = flat.entries[ordered[0]].node.drawingOrder != nil
            for (position, candidate) in ordered.enumerated() {
                let above = byDrawingOrder ? Array(ordered[(position + 1)...]) : []
                guard let page = flat.page(at: candidate, drawnBeneath: above, viewport: viewport) else { continue }
                pages[candidate] = page
                for lower in ordered[..<position] {
                    guard let visible = flat.entries[lower].node.frame?.intersection(viewport),
                          page.frame.encloses(visible, tolerance: tolerance),
                          byDrawingOrder || share(of: visible, in: viewport) >= minimumShare,
                          flat.subtree(lower).contains(where: { flat.entries[$0].node.isTelling }) else { continue }
                    for index in flat.subtree(lower) {
                        if lowestSealer[index] == nil { lowestSealer[index] = candidate }
                        topSealer[index] = candidate
                    }
                }
            }
        }
        let groups = Dictionary(grouping: lowestSealer.keys, by: { lowestSealer[$0]! })
        let beneath = groups.keys.sorted().compactMap { sealer -> Beneath? in
            guard let page = pages[sealer] else { return nil }
            let indexes = Set(groups[sealer] ?? [])
            return Beneath(name: flat.name(ofGroup: indexes.sorted(), viewport: viewport), under: page.name, elements: indexes.count, indexes: indexes)
        }
        let sealers = Set(topSealer.values).union(lowestSealer.values)
        return ScreenStack(
            pages: pages.keys.sorted().filter { sealers.contains($0) }.compactMap { pages[$0] },
            beneath: beneath,
            topSealer: topSealer
        )
    }

    static func share(of frame: UIFrame, in viewport: UIFrame) -> Double {
        (frame.width * frame.height) / (viewport.width * viewport.height)
    }
}

/// The tree in pre-order with parents, children and subtree ends, so the stack works in indexes.
struct FlatTree {
    struct Entry {
        let node: UINode
        let parent: Int?
        var children: [Int] = []
        var end = 0
    }

    private(set) var entries: [Entry] = []

    init(roots: [UINode]) {
        for root in roots {
            add(root, parent: nil)
        }
    }

    private mutating func add(_ node: UINode, parent: Int?) {
        let index = entries.count
        entries.append(Entry(node: node, parent: parent))
        if let parent { entries[parent].children.append(index) }
        for child in node.children {
            add(child, parent: index)
        }
        entries[index].end = entries.count
    }

    func subtree(_ index: Int) -> Range<Int> {
        index..<entries[index].end
    }

    /// Scrolled content and keyboards hold no screens.
    func isScrolledOrKeyboard(_ index: Int) -> Bool {
        if [.scrollView, .list].contains(entries[index].node.role) { return true }
        var current: Int? = index
        while let at = current {
            if entries[at].node.role == .keyboard { return true }
            current = entries[at].parent
        }
        return false
    }

    /// Siblings bottom first: by drawing order on Android (nil when any lacks one), else tree order.
    func bottomFirst(_ siblings: [Int]) -> [Int]? {
        let android = siblings.contains { entries[$0].node.isAndroidNode }
        guard android else { return siblings }
        let orders = siblings.compactMap { entries[$0].node.drawingOrder }
        guard orders.count == siblings.count else { return nil }
        return siblings.indices.sorted { orders[$0] != orders[$1] ? orders[$0] < orders[$1] : $0 < $1 }.map { siblings[$0] }
    }

    private static let overlayTypes = ["alert", "dialog", "sheet"]

    /// The candidate as a page: big, no control, overlay, LogBox or scrim, labelled from its top quarter past its middle; `above` adds Android siblings on it.
    func page(at index: Int, drawnBeneath above: [Int], viewport: UIFrame) -> ScreenStack.Page? {
        let node = entries[index].node
        guard let frame = node.frame, let visible = frame.intersection(viewport),
              ScreenStack.share(of: visible, in: viewport) >= ScreenStack.minimumShare,
              !node.role.isActionable, !node.role.isTextInput, node.role != .keyboard,
              !Self.overlayTypes.contains(where: { node.native.typeName?.lowercased().contains($0) == true }) else {
            return nil
        }
        let onTop = above.filter { sibling in
            entries[sibling].node.frame?.intersection(viewport).map { frame.encloses($0, tolerance: ScreenStack.tolerance) } ?? false
        }
        let content = Array(subtree(index).dropFirst()) + onTop.flatMap { Array(subtree($0)) }
        let nodes = content.map { entries[$0].node }
        guard !nodes.contains(where: { $0.role.isActionable && ($0.frame?.intersection(visible).map { ScreenStack.share(of: $0, in: visible) >= 0.8 } ?? false) }),
              !nodes.contains(where: { KnownOverlays.logBoxToast($0, viewport: viewport) != nil }),
              KnownOverlays.logBoxInspector(in: nodes, viewport: viewport) == nil else {
            return nil
        }
        let labelled = nodes.compactMap { node -> UIFrame? in
            guard node.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let shown = node.frame?.intersection(visible) else { return nil }
            return shown
        }
        guard let top = labelled.map(\.y).min(), let bottom = labelled.map({ $0.y + $0.height }).max(),
              top <= visible.y + visible.height / 4, bottom > visible.y + visible.height / 2 else {
            return nil
        }
        let name = node.id.flatMap(Self.nonEmpty) ?? headerOrFirstLabel(content.map { entries[$0].node }) ?? node.role.rawValue
        return ScreenStack.Page(index: index, name: name, frame: frame, content: Set([index] + content))
    }

    /// A covered screen's name: a screen-sized element's id, else a header's label, else the first plain label, else the first label.
    func name(ofGroup indexes: [Int], viewport: UIFrame) -> String {
        let nodes = indexes.map { entries[$0].node }
        if let id = nodes.first(where: { node in
            node.id.flatMap(Self.nonEmpty) != nil
                && (node.frame?.intersection(viewport).map { ScreenStack.share(of: $0, in: viewport) >= ScreenStack.minimumShare } ?? false)
        })?.id {
            return id
        }
        return headerOrFirstLabel(nodes) ?? "screen"
    }

    private func headerOrFirstLabel(_ nodes: [UINode]) -> String? {
        let labelled = nodes.filter { $0.label.flatMap(Self.nonEmpty) != nil }
        let pick = labelled.first { $0.role == .header } ?? labelled.first { !$0.role.isActionable } ?? labelled.first
        return pick?.label.flatMap(Self.nonEmpty)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension UINode {
    /// Labelled or actionable: something a covered screen shows or offers.
    var isTelling: Bool {
        role.isActionable || label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isAndroidNode: Bool {
        if case .android = native { return true }
        return false
    }
}

extension UIFrame {
    /// True when `other` lies inside this frame, give or take `tolerance` on each edge.
    public func encloses(_ other: UIFrame, tolerance: Double) -> Bool {
        other.x >= x - tolerance && other.y >= y - tolerance
            && other.x + other.width <= x + width + tolerance && other.y + other.height <= y + height + tolerance
    }
}
