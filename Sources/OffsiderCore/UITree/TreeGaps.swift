import Foundation

/// Which parts of a screen a tree already accounts for, on a coarse grid, and where a point read could still find something.
struct TreeGaps {
    static let cellSide = 20.0
    /// How far apart point reads go, in cells: a row of text is about two high, a button about three wide.
    static let columnStride = 3
    static let rowStride = 2

    let viewport: UIFrame
    private let columns: Int
    private let rows: Int
    private var covered: [Bool]

    init(viewport: UIFrame) {
        self.viewport = viewport
        columns = max(1, Int((viewport.width / Self.cellSide).rounded(.up)))
        rows = max(1, Int((viewport.height / Self.cellSide).rounded(.up)))
        covered = Array(repeating: false, count: columns * rows)
    }

    /// Marks every cell `frame` touches.
    mutating func cover(_ frame: UIFrame) {
        let first = cell(atX: frame.x, y: frame.y)
        let last = cell(atX: frame.x + frame.width, y: frame.y + frame.height)
        for row in first.row...last.row {
            for column in first.column...last.column { covered[row * columns + column] = true }
        }
    }

    mutating func cover(cellAt point: UIPoint) {
        let at = cell(atX: point.x, y: point.y)
        covered[at.row * columns + at.column] = true
    }

    func isCovered(_ point: UIPoint) -> Bool {
        let at = cell(atX: point.x, y: point.y)
        return covered[at.row * columns + at.column]
    }

    private func cell(atX x: Double, y: Double) -> (column: Int, row: Int) {
        (
            Int(min(Double(columns - 1), max(0, (x - viewport.x) / Self.cellSide))),
            Int(min(Double(rows - 1), max(0, (y - viewport.y) / Self.cellSide)))
        )
    }

    /// Up to `count` of the points still worth reading, spread evenly over what is left.
    func round(of count: Int) -> [UIPoint] {
        var points: [UIPoint] = []
        for row in stride(from: 0, to: rows, by: Self.rowStride) {
            for column in stride(from: 1, to: columns, by: Self.columnStride) where !covered[row * columns + column] {
                points.append(UIPoint(x: viewport.x + (Double(column) + 0.5) * Self.cellSide, y: viewport.y + (Double(row) + 0.5) * Self.cellSide))
            }
        }
        guard points.count > count, count > 0 else { return points }
        return (0..<count).map { points[(2 * $0 + 1) * points.count / (2 * count)] }
    }
}

extension UINode {
    /// Content a person would read or touch, on screen: not the app or a window, not a screen-sized backdrop, and labelled, actionable or a small identified view.
    func isContent(in viewport: UIFrame) -> Bool {
        guard role != .application, role != .window, role != .keyboard, let frame, frame.width > 0, frame.height > 0, frame.isVisible(in: viewport),
              frame.width * frame.height < viewport.width * viewport.height * TreeGapFill.backdropShare else { return false }
        return normalizedLabel != nil || normalizedID != nil || isActionable
    }

    /// A hit-test can land on a listed element's own text or icon, which says nothing a person would miss.
    func holdsOwnText(_ inner: UINode) -> Bool {
        guard children.isEmpty, let frame, let innerFrame = inner.frame, frame.encloses(innerFrame, tolerance: 1) else { return false }
        return normalizedLabel == inner.normalizedLabel || (isActionable && (inner.role == .text || inner.role == .image))
    }

    /// The same view read twice, whatever drawing order or state each read gave it.
    func isSameView(as other: UINode) -> Bool {
        guard role == other.role, normalizedID == other.normalizedID, normalizedLabel == other.normalizedLabel,
              let frame, let otherFrame = other.frame else { return false }
        return abs(frame.x - otherFrame.x) <= 1 && abs(frame.y - otherFrame.y) <= 1
            && abs(frame.width - otherFrame.width) <= 1 && abs(frame.height - otherFrame.height) <= 1
    }
}

/// Adds to a tree what an app draws but hides from accessibility: the plain read honours that mark, a point read on iOS and an every-view read on Android do not.
public enum TreeGapFill {
    /// Of the viewport: a leaf this large is a backdrop or a web view rather than content.
    static let backdropShare = 0.6
    /// Point reads run together, as a simulator answers them at once, in rounds up to these limits.
    public static let roundSize = 24
    public static let readLimit = 96
    public static let timeLimit: TimeInterval = 1.5
    static let sampleColumns = 3
    /// A hit-test takes about 25 ms in the app, one after another: this many fit inside a tree read, and any one that finds something starts the scan.
    public static let earlySampleRows = 4
    /// For a selector that has already missed, where looking harder is worth the wait.
    public static let sampleRows = 8

    /// Where a fill first looks, spread over `screen` below the status bar, which no app draws in; each column is staggered so a full-width row a third of a step high cannot slip between them.
    public static func samplePoints(in screen: UIFrame, rows: Int = sampleRows, belowStatusBar statusBar: Double = 0) -> [UIPoint] {
        let height = screen.height - statusBar
        return (0..<rows).flatMap { row in
            (0..<sampleColumns).map { column in
                UIPoint(
                    x: screen.x + screen.width * (Double(column) + 0.5) / Double(sampleColumns),
                    y: screen.y + statusBar + height * (Double(row) + (Double(column) + 0.5) / Double(sampleColumns)) / Double(rows)
                )
            }
        }
    }

    /// `tree` with what point reads find on a simulator. A hit-test passes over a hidden view when a listed one lies beneath it, so only points the tree leaves empty are read, and only a sample answering with content the tree does not list starts a scan.
    /// `samples` tells which sample points to read and which answers to read in full; `read` does both for further points at once. `now` is a clock in seconds.
    @MainActor
    public static func filling(
        _ tree: UITree,
        points: [UIPoint],
        samples: ([Bool], (UINode) -> Bool) async -> [UINode?],
        read: ([UIPoint], (UINode) -> Bool) async -> [UINode?],
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async -> UITree {
        guard let viewport = tree.visibleRect, viewport.width > 0, viewport.height > 0,
              let app = tree.roots.firstIndex(where: { $0.role == .application }) else { return tree }
        let host = tree.roots[app].iosPID
        let listed = tree.roots.flatMap { $0.flattened() }
        let isOwn = { (hit: UINode) in (hit.iosPID == nil || hit.iosPID == host) && hit.isContent(in: viewport) }
        var found: [UINode] = []
        let isNew = { (hit: UINode) in
            isOwn(hit) && !listed.contains { $0.isSameView(as: hit) || $0.holdsOwnText(hit) } && !found.contains { $0.isSameView(as: hit) }
        }
        var gaps = TreeGaps(viewport: viewport)
        for node in listed where node.children.isEmpty && node.isContent(in: viewport) {
            if let frame = node.frame { gaps.cover(frame) }
        }

        func take(_ points: [UIPoint], _ hits: [UINode?]) {
            for (point, hit) in zip(points, hits) {
                gaps.cover(cellAt: point)
                guard let hit, isOwn(hit), let frame = hit.frame else { continue }
                gaps.cover(frame)
                if isNew(hit) { found.append(hit) }
            }
        }

        let wanted = points.map { !gaps.isCovered($0) }
        guard wanted.contains(true) else { return tree }
        var answers = await samples(wanted, isNew)
        // A hit-test can fail when it starts as a simulator's session opens, and then all of them do; one more try tells that from white space.
        if zip(wanted, answers).allSatisfy({ wanted, answer in !wanted || answer == nil }) {
            answers = zip(points, await read(points, isNew)).map { point, hit in gaps.isCovered(point) ? nil : hit }
        }
        take(points, answers)
        guard !found.isEmpty else { return tree }

        var reads = 0
        let started = now()
        while reads < readLimit, now() - started < timeLimit {
            let next = gaps.round(of: min(roundSize, readLimit - reads))
            guard !next.isEmpty else { break }
            reads += next.count
            take(next, await read(next, isNew))
        }

        let kept = withoutRepeats(found).sorted { first, second in
            let a = first.frame ?? viewport, b = second.frame ?? viewport
            return a.y != b.y ? a.y < b.y : a.x < b.x
        }
        var filled = tree
        // First among the app's children, so what the tree lists counts as drawn over them until a hit-test says otherwise.
        filled.roots[app].children.insert(contentsOf: kept, at: 0)
        filled.filledFromGaps = kept.count
        return filled
    }

    /// `plain` with what `everyView` adds that a touch at its centre would reach, as Android's drawing order tells: the structure comes from `everyView`, so a hidden page drawn over a listed one stays over it. Unchanged when it adds nothing.
    public static func filling(_ plain: UITree, from everyView: UITree) -> UITree {
        guard let viewport = plain.visibleRect, viewport.width > 0, viewport.height > 0 else { return plain }
        let listed = plain.roots.flatMap { $0.flattened() }
        let found = everyView.roots.flatMap { $0.flattened() }.filter { node in
            guard node.isContent(in: viewport), let center = node.frame?.center, !listed.contains(where: { $0.isSameView(as: node) }) else { return false }
            let chain = UITree.hitChain(in: everyView.roots, at: center)
            guard let at = chain.firstIndex(where: { $0.isSameElement(as: node) }) else { return false }
            // A listed element's own text or icon says nothing a person would miss.
            return !chain[..<at].contains { above in
                above.normalizedLabel != nil && above.isContent(in: viewport) && listed.contains { $0.isSameView(as: above) }
            }
        }
        let kept = withoutRepeats(found)
        guard !kept.isEmpty else { return plain }
        var filled = plain
        filled.roots = everyView.roots.map { pruned($0, keeping: kept, listed: listed, isRoot: true) ?? $0 }
        filled.filledFromGaps = kept.count
        return filled
    }

    /// `node` with only the branches that hold something listed or found.
    private static func pruned(_ node: UINode, keeping kept: [UINode], listed: [UINode], isRoot: Bool = false) -> UINode? {
        var copy = node
        copy.children = node.children.compactMap { pruned($0, keeping: kept, listed: listed) }
        guard isRoot || !copy.children.isEmpty || kept.contains(where: { $0.isSameElement(as: node) }) || listed.contains(where: { $0.isSameView(as: node) }) else {
            return nil
        }
        return copy
    }

    /// A text inside a found element that says the same adds nothing.
    private static func withoutRepeats(_ found: [UINode]) -> [UINode] {
        found.filter { node in
            guard let label = node.normalizedLabel, let frame = node.frame else { return true }
            return !found.contains { other in
                guard let outer = other.frame, other.normalizedLabel == label else { return false }
                return outer != frame && outer.encloses(frame, tolerance: 1)
            }
        }
    }
}
