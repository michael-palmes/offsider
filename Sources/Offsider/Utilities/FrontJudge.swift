import Foundation
import OffsiderCore

/// The one judgement of what is on screen that selectors, `tap --topmost`, `wait`, `assert` and `describe-ui --on-screen` share:
/// an element counts when its frame meets the screen, no page is drawn over its screen, and a touch at its point reaches it,
/// judged as a tap's cover check judges its target (the simulator's hit-test, Android's drawing order). Only a confident cover counts.
@MainActor
enum FrontJudge {
    /// At most this many points are hit-tested on an iOS simulator in one read, centres all at once and then the parts beside covers; the rest keep the tree's word.
    static let hitLimit = 24

    /// Judges the elements at `indexes` (pre-order over `tree.roots`) and stores the reading on `tree`, merged with any it had; `everyPoint` hit-tests each on a simulator, not only those something labelled overlaps.
    static func read(_ indexes: some Sequence<Int>, in tree: inout UITree, index: TreeIndex? = nil, backend: any DeviceBackend, device: DeviceID, everyPoint: Bool = false) async {
        let reader = tree.platform == .android ? nil : PointReader(backend: backend, device: device)
        var reading = tree.front ?? FrontReading()
        let judged = tree
        await Timings.measure("front") {
            let plan = Plan(tree: judged, indexes: indexes, reading: reading, spareReads: reader == nil ? nil : everyPoint ? hitLimit : 0, index: index)
            let contested = Array((everyPoint ? plan.unblocked : plan.contested).prefix(hitLimit))
            let hits = await hitTests(contested.map { ($0.index, $0.judging) }, reader: reader)
            plan.record(into: &reading, hits: hits, hitTested: reader != nil, platform: judged.platform)
            if let reader {
                await readParts(of: contested, into: &reading, in: judged, shared: plan.shared, reader: reader)
            }
            plan.settleGroups(in: &reading)
        }
        tree.front = reading
    }

    /// A tap goes to the part of a covered element beside its cover, so an element counts when that part reaches it, read as a tap reads it and only once its centre is known to be covered.
    private static func readParts(of contested: [Plan.Entry], into reading: inout FrontReading, in tree: UITree, shared: TapCover.Shared?, reader: PointReader) async {
        let spare = (hitLimit - contested.count) / TapCover.partTries
        let covered = contested.compactMap { entry -> (Plan.Entry, UIFrame)? in
            guard let verdict = reading.covered[entry.index], verdict.leavesPartShowing, let frame = verdict.touchFrame else { return nil }
            return (entry, frame)
        }.prefix(spare)
        guard !covered.isEmpty else { return }
        let reached = await withTaskGroup(of: Int?.self) { group in
            for (entry, frame) in covered {
                group.addTask { @MainActor in
                    await TapCover.reachablePart(of: entry.resolution, beside: frame, in: tree, shared: shared, reader: reader) == nil ? nil : entry.index
                }
            }
            var indexes: [Int] = []
            for await index in group {
                if let index { indexes.append(index) }
            }
            return indexes
        }
        for index in reached {
            reading.covered[index] = nil
        }
    }

    /// One read per point on a simulator, with no retry: an answer read too soon only leaves an element counted.
    struct PointReader {
        let hitTester: any PointHitTesting
        let device: DeviceID

        init?(backend: any DeviceBackend, device: DeviceID) {
            guard let hitTester = backend as? any PointHitTesting else { return nil }
            self.hitTester = hitTester
            self.device = device
        }

        func read(at point: UIPoint) async -> UINode? {
            (try? await hitTester.quickHitTest(at: point, on: device)) ?? nil
        }
    }

    /// `read` for every on-screen match of `queries`.
    static func read(matching queries: [AccessibilityQuery], elementType: String?, in tree: inout UITree, backend: any DeviceBackend, device: DeviceID, everyPoint: Bool = false) async {
        let index = TreeIndex(roots: tree.roots)
        var indexes = Set<Int>()
        for query in queries {
            let found = AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: elementType)
            for match in found.onScreen {
                indexes.formUnion(index.indexes(of: match))
            }
        }
        guard !indexes.isEmpty else { return }
        await read(indexes.sorted(), in: &tree, index: index, backend: backend, device: device, everyPoint: everyPoint)
    }

    /// The elements judged without a device: pages and the drawing order, and which need a hit-test.
    struct Plan {
        struct Entry {
            let index: Int
            let resolution: TapResolution
            let judging: TapCover.Judging
        }

        /// The app and its windows hold the screen rather than sit on it.
        static let containerRoles: Set<UIRole> = [.application, .window]

        var beneath: [Int: String] = [:]
        /// Inside the screen, but past an edge of its scroll view.
        var clipped: [Int: OffScreenSide] = [:]
        var entries: [Entry] = []
        /// Each unlabelled group asked about, with the labelled elements and controls it holds.
        var groups: [Int: [Int]] = [:]
        /// What every judgement on the tree shares, for the parts beside covers read after.
        var shared: TapCover.Shared?

        /// `spareReads` is how many points may be hit-tested for what a group holds, beyond those asked about: a group needing more stays as its own point says. Nil when reading costs nothing. `index`, when given, is already read over `tree.roots`.
        init(tree: UITree, indexes: some Sequence<Int>, reading: FrontReading, spareReads: Int? = nil, index: TreeIndex? = nil) {
            guard let viewport = tree.viewport else { return }
            let indexed = index ?? TreeIndex(roots: tree.roots)
            let flat = indexed.nodes
            let stack = ScreenStack.build(indexed, viewport: viewport)
            guard let shared = TapCover.Shared(tree, index: indexed, stack: stack) else { return }
            self.shared = shared
            let occluders = AccessibilityTargetResolver.Occluders(indexed, viewport: viewport)
            let indicators = ScrollIndicator.all(in: tree.roots)
            var asked = Set(indexes)
            for index in asked.sorted() where index < flat.count && Self.isGroup(flat[index]) && reading.covered[index] == nil && reading.beneath[index] == nil {
                let held = (index + 1)..<indexed.subtree(index).upperBound
                let telling = held.filter { position in
                    flat[position].isTelling && flat[position].frame?.isVisible(in: viewport) == true && !indicators.contains { $0.isSameElement(as: flat[position]) }
                }
                guard !telling.isEmpty, spareReads.map({ telling.filter { !asked.contains($0) }.count <= $0 }) ?? true else { continue }
                groups[index] = telling
                asked.formUnion(telling)
            }
            for index in asked.sorted() where index < flat.count && reading.judged[index] == nil && reading.beneath[index] == nil && reading.clipped[index] == nil {
                let node = flat[index]
                guard !Self.containerRoles.contains(node.role), let frame = node.frame, node.hasPositiveFrame, frame.isVisible(in: viewport) else { continue }
                if let page = stack.page(over: index) {
                    beneath[index] = page.name
                    continue
                }
                guard let resolution = AccessibilityTargetResolver.resolution(of: node, among: occluders, stack: stack) else {
                    clipped[index] = AccessibilityTargetResolver.sidePastScrollView(of: node, frame: frame, viewport: viewport, in: indexed) ?? .below
                    continue
                }
                guard let judging = TapCover.Judging(resolution, on: shared, beneath: false) else { continue }
                entries.append(Entry(index: index, resolution: resolution, judging: judging))
            }
        }

        private static func isGroup(_ node: UINode) -> Bool {
            !containerRoles.contains(node.role) && !node.role.isActionable && node.normalizedLabel == nil && !node.children.isEmpty
        }

        /// A group is drawn on with what it holds, so its own point says little: one whose every labelled element and control a touch would miss is out of reach too.
        func settleGroups(in reading: inout FrontReading) {
            for (group, held) in groups.sorted(by: { $0.key > $1.key }) where reading.covered[group] == nil && reading.beneath[group] == nil {
                guard held.allSatisfy(reading.unreached.contains) else { continue }
                if let page = held.compactMap({ [beneath = reading.beneath] in beneath[$0] }).first {
                    reading.beneath[group] = page
                } else if let verdict = held.compactMap({ [covered = reading.covered] in covered[$0] }).first {
                    reading.covered[group] = verdict
                    reading.judged[group]?.verdict = verdict
                }
            }
        }

        /// The judged elements something may draw over, which an iOS simulator's hit-test settles.
        var contested: [Entry] {
            unblocked.filter { $0.judging.isContested }
        }

        /// The judged elements the keyboard does not cover.
        var unblocked: [Entry] {
            entries.filter { $0.judging.keyboard == nil }
        }

        func record(into reading: inout FrontReading, hits: [Int: UINode], hitTested: Bool, platform: DevicePlatform) {
            reading.beneath.merge(beneath) { _, new in new }
            reading.clipped.merge(clipped) { _, new in new }
            for entry in entries {
                if let keyboard = entry.judging.keyboard {
                    let verdict = CoverVerdict(cover: keyboard, evidence: platform == .android ? .drawingOrder : .treeOrder, isConfident: true)
                    reading.covered[entry.index] = verdict
                    reading.judged[entry.index] = FrontReading.Judged(point: entry.judging.point, verdict: verdict)
                    continue
                }
                // A simulator point left unread keeps the tree's word, and a tap there reads it afresh.
                if hitTested, hits[entry.index] == nil, entry.judging.isContested { continue }
                let verdict = entry.judging.verdict(hit: hits[entry.index])
                // An empty screen-sized answer may be a point read mid-transition, which only a tap's retrying hit-test can read past.
                let unsure = verdict?.isConfident != true && hits[entry.index].map { hit in
                    AccessibilityFetcher.isTransientPointFallback(hit, at: AccessibilityPoint(x: entry.judging.point.x, y: entry.judging.point.y))
                } == true
                reading.judged[entry.index] = FrontReading.Judged(point: entry.judging.point, verdict: verdict, ownHit: hits[entry.index].map(entry.judging.surelyReaches(hit:)), unsure: unsure)
                if let verdict, verdict.isConfident {
                    reading.covered[entry.index] = verdict
                }
            }
        }
    }

    /// Each point's read, all at once; a failed read leaves its point out.
    private static func hitTests(_ points: [(Int, TapCover.Judging)], reader: PointReader?) async -> [Int: UINode] {
        guard let reader, !points.isEmpty else { return [:] }
        return await withTaskGroup(of: (Int, UINode?).self) { group in
            for (index, judging) in points {
                group.addTask { @MainActor in
                    (index, await reader.read(at: judging.point))
                }
            }
            var hits: [Int: UINode] = [:]
            for await (index, hit) in group {
                if let hit { hits[index] = hit }
            }
            return hits
        }
    }
}
