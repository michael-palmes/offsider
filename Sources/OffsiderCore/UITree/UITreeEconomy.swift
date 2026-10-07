import Foundation

/// Where an off-screen node lies against the visible rect.
public enum OffScreenSide: String, Sendable {
    case above, below, left, right
}

/// One line of text output before the byte budget: a node, or a run of off-screen nodes.
public struct UITextLine: Equatable, Sendable {
    public var depth: Int
    public var text: String
    /// How many nodes the line stands for: 1 for a node, the item count for a run.
    public var nodes: Int
}

/// The text view's economy: labels a parent already shows are folded, off-screen runs are summarised, output fits a byte budget.
public enum UITreeEconomy {
    /// Nested text stops indenting at this many levels.
    public static let maxIndent = 10

    public static let deviceTruncationMarker = "# the device stopped listing nodes at its limit; this tree is incomplete"

    static let editableRoles: Set<UIRole> = [.textField, .secureTextField, .searchField, .textArea]

    public static func budgetMarker(cut: Int, maxBytes: Int) -> String {
        "# truncated: \(cut) more node\(cut == 1 ? "" : "s") past the \(maxBytes)-byte budget; pass --max-bytes 0 for all, or narrow with --actionable"
    }

    public static func foldedLine(_ count: Int) -> String {
        "# folded \(count) repeated label\(count == 1 ? "" : "s")"
    }

    /// `# beneath: "Products" (42 elements) under "Kettle"`: a screen a page covers, left out of on-screen text.
    public static func beneathLine(_ screen: ScreenStack.Beneath) -> String {
        let count = "\(screen.elements) element\(screen.elements == 1 ? "" : "s")"
        return "# beneath: \(UITreeRenderer.quoted(SelectorText.truncated(screen.name, limit: 40))) (\(count)) under \(UITreeRenderer.quoted(SelectorText.truncated(screen.under, limit: 40)))"
    }

    /// The node and run lines in document order, how many nodes had a label folded, and the covered screens left out.
    static func lines(
        _ tree: UITree,
        _ options: UITreeRenderOptions,
        fields: Set<UIField>,
        render: @escaping (UINode, _ label: String?, _ value: String?) -> String
    ) -> (lines: [UITextLine], folded: Int, beneath: [ScreenStack.Beneath]) {
        var walker = Walker(tree: tree, options: options, fields: fields, render: render)
        for root in tree.roots {
            walker.visit(root, depth: 0, ancestorLabel: nil, ancestor: .absent)
        }
        walker.flushRun()
        return (walker.lines, walker.folded, walker.beneath)
    }

    /// The header, the lines that fit `maxBytes` (nil for all) with a cut marker, then the closing notes, which the budget never cuts.
    static func budgeted(_ lines: [UITextLine], header: String, folded: Int, sourceTruncated: Bool, maxBytes: Int?, beneath: [ScreenStack.Beneath] = []) -> String {
        let rendered = lines.map { String(repeating: "  ", count: min($0.depth, maxIndent)) + $0.text + "\n" }
        var closing = ""
        if sourceTruncated { closing += deviceTruncationMarker + "\n" }
        if folded > 0 { closing += foldedLine(folded) + "\n" }
        for screen in beneath { closing += beneathLine(screen) + "\n" }
        let head = header + "\n"
        let total = rendered.reduce(head.utf8.count + closing.utf8.count) { $0 + $1.utf8.count }
        guard let maxBytes, total > maxBytes else {
            return head + rendered.joined() + closing
        }
        let allNodes = lines.reduce(0) { $0 + $1.nodes }
        var used = head.utf8.count + closing.utf8.count + budgetMarker(cut: allNodes, maxBytes: maxBytes).utf8.count + 1
        var output = head
        var kept = 0
        for line in rendered {
            guard kept == 0 || used + line.utf8.count <= maxBytes else { break }
            output += line
            used += line.utf8.count
            kept += 1
        }
        let cut = lines.dropFirst(kept).reduce(0) { $0 + $1.nodes }
        if cut > 0 { output += budgetMarker(cut: cut, maxBytes: maxBytes) + "\n" }
        return output + closing
    }

    /// The nearest ancestor that passes every filter but on-screen: none, on screen, or off screen.
    enum Ancestor {
        case absent, onScreen, offScreen
    }

    struct Run {
        var side: OffScreenSide
        var depth: Int
        var count: Int
        var first: String
        var last: String
    }

    struct Walker {
        let options: UITreeRenderOptions
        let fields: Set<UIField>
        let render: (UINode, String?, String?) -> String
        let rect: UIFrame?
        let otherFilters: UITreeFilter
        let summarisesRuns: Bool
        /// Screens a page covers, which on-screen output leaves out; and their elements' pre-order indexes.
        let beneath: [ScreenStack.Beneath]
        let covered: Set<Int>
        /// Nested output keeps the ancestors of matches, by pre-order index.
        var kept: [Bool] = []
        var index = 0
        var lines: [UITextLine] = []
        var folded = 0
        var run: Run?

        init(tree: UITree, options: UITreeRenderOptions, fields: Set<UIField>, render: @escaping (UINode, String?, String?) -> String) {
            self.options = options
            self.fields = fields
            self.render = render
            rect = tree.visibleRect
            var others = options.filter
            others.onScreen = false
            otherFilters = others
            summarisesRuns = options.filter.onScreen && rect != nil
            beneath = summarisesRuns ? ScreenStack.build(roots: tree.roots, viewport: tree.viewport).beneath : []
            covered = Set(beneath.flatMap(\.indexes))
            if !options.flat {
                for root in tree.roots {
                    _ = mark(root)
                }
            }
        }

        private mutating func mark(_ node: UINode) -> Bool {
            let position = kept.count
            kept.append(false)
            var any = !covered.contains(position) && options.filter.matches(node, visibleRect: rect)
            for child in node.children where mark(child) {
                any = true
            }
            kept[position] = any
            return any
        }

        mutating func visit(_ node: UINode, depth: Int, ancestorLabel: String?, ancestor: Ancestor) {
            let position = index
            index += 1
            let isCovered = covered.contains(position)
            let matches = !isCovered && options.filter.matches(node, visibleRect: rect)
            let shown = options.flat ? matches : kept[position]
            let passesOthers = !isCovered && otherFilters.matches(node, visibleRect: rect)
            var childDepth = depth
            var childLabel = ancestorLabel
            if shown {
                flushRun()
                if let text = shownLine(node, ancestorLabel: ancestorLabel) {
                    lines.append(UITextLine(depth: depth, text: text, nodes: 1))
                    childDepth = depth + 1
                    childLabel = node.label
                }
            } else if summarisesRuns, passesOthers, ancestor != .offScreen,
                      let frame = node.frame, let rect, let side = Self.side(of: frame, in: rect) {
                addToRun(node, side: side, depth: depth)
            }
            let childAncestor: Ancestor = passesOthers ? (matches ? .onScreen : .offScreen) : ancestor
            for child in node.children {
                visit(child, depth: childDepth, ancestorLabel: childLabel, ancestor: childAncestor)
            }
        }

        /// The node's line with folded text left out, or nil when folding leaves nothing worth a line.
        private mutating func shownLine(_ node: UINode, ancestorLabel: String?) -> String? {
            let shownValue = fields.contains(.value) ? node.value.flatMap { $0.isEmpty ? nil : $0 } : nil
            guard fields.contains(.label), let label = node.label, !label.isEmpty else {
                return render(node, nil, shownValue)
            }
            var value = shownValue
            var didFold = false
            if value == label, !editableRoles.contains(node.role) {
                value = nil
                didFold = true
            }
            let repeated = ancestorLabel.map { $0 == label || $0.components(separatedBy: ", ").contains(label) } ?? false
            if didFold || repeated { folded += 1 }
            guard repeated else { return render(node, label, value) }
            let hasID = fields.contains(.id) && !(node.id ?? "").isEmpty
            guard hasID || value != nil || node.isActionable || node.state.checked != nil || node.state.selected == true else {
                return nil
            }
            return render(node, nil, value)
        }

        private mutating func addToRun(_ node: UINode, side: OffScreenSide, depth: Int) {
            let name = Self.name(node)
            if var current = run, current.side == side {
                current.count += 1
                current.last = name
                run = current
                return
            }
            flushRun()
            run = Run(side: side, depth: depth, count: 1, first: name, last: name)
        }

        mutating func flushRun() {
            guard let current = run else { return }
            run = nil
            var text = "[off-screen \(current.side.rawValue)] \(current.count) item\(current.count == 1 ? "" : "s"): \(current.first)"
            if current.count > 1 { text += " to \(current.last)" }
            lines.append(UITextLine(depth: current.depth, text: text, nodes: current.count))
        }

        /// The edge the frame lies wholly past; nil for an empty frame, or one inside the rect that is too small to see.
        static func side(of frame: UIFrame, in rect: UIFrame) -> OffScreenSide? {
            guard frame.width > 0, frame.height > 0 else { return nil }
            if frame.y >= rect.y + rect.height { return .below }
            if frame.y + frame.height <= rect.y { return .above }
            if frame.x >= rect.x + rect.width { return .right }
            if frame.x + frame.width <= rect.x { return .left }
            return nil
        }

        /// `id=<id>`, else the quoted label, else the role, each cut to 40 characters.
        static func name(_ node: UINode) -> String {
            if let id = node.id, !id.isEmpty {
                return "id=" + UITreeRenderer.token(SelectorText.truncated(id, limit: 40))
            }
            if let label = node.label, !label.isEmpty {
                return UITreeRenderer.quoted(SelectorText.truncated(label, limit: 40))
            }
            return node.role.rawValue
        }
    }
}
