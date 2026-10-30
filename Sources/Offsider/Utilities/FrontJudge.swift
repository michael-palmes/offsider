import Foundation
import OffsiderCore

/// The one judgement of what is on screen that selectors, `tap --topmost`, `wait`, `assert` and `describe-ui --on-screen` share:
/// an element counts when its frame meets the screen, no page is drawn over its screen, and a touch at its point reaches it,
/// judged as a tap's cover check judges its target (the simulator's hit-test, Android's drawing order). Only a confident cover counts.
@MainActor
enum FrontJudge {
    /// At most this many points are hit-tested on an iOS simulator in one read, all at once; the rest keep the tree's word.
    static let hitLimit = 24

    /// Judges the elements at `indexes` (pre-order over `tree.roots`) and stores the reading on `tree`, merged with any it had; `everyPoint` hit-tests each on a simulator, not only those something labelled overlaps.
    static func read(_ indexes: some Sequence<Int>, in tree: inout UITree, backend: any DeviceBackend, device: DeviceID, everyPoint: Bool = false) async {
        let reader = tree.platform == .android ? nil : PointReader(backend: backend, device: device)
        var reading = tree.front ?? FrontReading()
        let judged = tree
        await Timings.measure("front") {
            let plan = Plan(tree: judged, indexes: indexes, reading: reading)
            let contested = Array((everyPoint ? plan.unblocked : plan.contested).prefix(hitLimit))
            // A tap aims at the part of a covered element beside its cover, so that part is read in the same round as the centre.
            let parts = reader == nil ? [] : contested.compactMap { entry -> (Int, TapCover.Judging)? in
                let covers = entry.judging.candidates.compactMap(\.frame)
                guard let first = covers.first,
                      let moved = TapCover.clearParts(of: entry.resolution, beside: covers.dropFirst().reduce(first, Self.bounds), in: judged).first,
                      let judging = TapCover.Judging(moved, in: judged, beneath: false), judging.keyboard == nil else { return nil }
                return (entry.index, judging)
            }
            async let centres = hitTests(contested.map { ($0.index, $0.judging) }, reader: reader)
            async let beside = hitTests(parts, reader: reader)
            let (hits, partHits) = await (centres, beside)
            plan.record(into: &reading, hits: hits, hitTested: reader != nil, platform: judged.platform)
            for (index, judging) in parts where reading.covered[index]?.evidence == .hitTest {
                if let hit = partHits[index], judging.surelyReaches(hit: hit) { reading.covered[index] = nil }
            }
        }
        tree.front = reading
    }

    /// The smallest frame holding both.
    private static func bounds(_ a: UIFrame, _ b: UIFrame) -> UIFrame {
        let left = min(a.x, b.x), top = min(a.y, b.y)
        return UIFrame(x: left, y: top, width: max(a.x + a.width, b.x + b.width) - left, height: max(a.y + a.height, b.y + b.height) - top)
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
        let flat = tree.roots.flatMap { $0.flattened() }
        var indexes = Set<Int>()
        for query in queries {
            let found = AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: elementType)
            for match in found.onScreen {
                indexes.formUnion(flat.indices.filter { flat[$0].isSameElement(as: match) })
            }
        }
        guard !indexes.isEmpty else { return }
        await read(indexes.sorted(), in: &tree, backend: backend, device: device, everyPoint: everyPoint)
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
        var entries: [Entry] = []

        init(tree: UITree, indexes: some Sequence<Int>, reading: FrontReading) {
            guard let viewport = tree.viewport else { return }
            let flat = tree.roots.flatMap { $0.flattened() }
            let stack = ScreenStack.build(roots: tree.roots, viewport: viewport)
            for index in indexes where index < flat.count && reading.judged[index] == nil && reading.beneath[index] == nil {
                let node = flat[index]
                guard !Self.containerRoles.contains(node.role), let frame = node.frame, node.hasPositiveFrame, frame.isVisible(in: viewport) else { continue }
                if let page = stack.page(over: index) {
                    beneath[index] = page.name
                    continue
                }
                guard let resolution = AccessibilityTargetResolver.resolution(of: node, roots: tree.roots, viewport: viewport, stack: stack),
                      let judging = TapCover.Judging(resolution, in: tree, beneath: false) else { continue }
                entries.append(Entry(index: index, resolution: resolution, judging: judging))
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
                reading.judged[entry.index] = FrontReading.Judged(point: entry.judging.point, verdict: verdict)
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
