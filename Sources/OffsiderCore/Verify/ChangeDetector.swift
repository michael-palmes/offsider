import Foundation

/// The part of the screen that kept moving, as the flags a `--settled` wait takes to leave it out.
public indirect enum MovingPart: Equatable, Sendable {
    case id(String)
    case region(PointRegion)
    /// Movers no one flag holds, each with its own.
    case parts([MovingPart])

    /// A flag leaving out this share of the screen or more would leave nothing worth waiting for, unless the rest shows at least what remains of the screen.
    static let mostOfScreen = 0.8

    /// At most this many flags, as a screen moving in more places than this is not settling.
    static let mostFlags = 4

    /// `--ignore-id panel`, `--ignore-region 0,210,390,280`; an off-screen origin takes `=`, as the parser reads a bare leading dash as an option.
    public var flag: String {
        switch self {
        case .id(let id):
            return "--ignore-id \(id)"
        case .region(let region):
            let text = "\(Int(region.x)),\(Int(region.y)),\(Int(region.width)),\(Int(region.height))"
            return text.hasPrefix("-") ? "--ignore-region=\(text)" : "--ignore-region \(text)"
        case .parts(let parts):
            return parts.map(\.flag).joined(separator: " ")
        }
    }

    var ids: [String] {
        switch self {
        case .id(let id): [id]
        case .region: []
        case .parts(let parts): parts.flatMap(\.ids)
        }
    }

    var regions: [PointRegion] {
        switch self {
        case .id: []
        case .region(let region): [region]
        case .parts(let parts): parts.flatMap(\.regions)
        }
    }

    /// Letters, digits and `._:/-`, not starting with a dash, so the flag pastes as it prints.
    static func fitsCommandLine(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && !id.hasPrefix("-")
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:/-".unicodeScalars.contains($0)) }
    }

    /// The whole points around `frames`; with `screen`, only what is on it, and nil when nothing is.
    static func bounds(of frames: [AccessibilitySnapshot.Frame], within screen: AccessibilitySnapshot.Frame?) -> AccessibilitySnapshot.Frame? {
        var left = Double.infinity, top = Double.infinity, right = -Double.infinity, bottom = -Double.infinity
        for frame in frames where frame.width > 0 && frame.height > 0 {
            left = min(left, frame.x)
            top = min(top, frame.y)
            right = max(right, frame.x + frame.width)
            bottom = max(bottom, frame.y + frame.height)
        }
        if let screen {
            left = max(left, screen.x, 0)
            top = max(top, screen.y, 0)
            right = min(right, screen.x + screen.width)
            bottom = min(bottom, screen.y + screen.height)
        }
        guard left.isFinite, top.isFinite, right > left, bottom > top else { return nil }
        let (x, y) = (left.rounded(.down), top.rounded(.down))
        return AccessibilitySnapshot.Frame(x: x, y: y, width: (right - x).rounded(.up), height: (bottom - y).rounded(.up))
    }
}

/// What kept moving across a `--settled` wait: where each element has been, and the latest reads to prove a flag against.
public struct MoveLog: Sendable {
    static let keptPairs = 4

    public private(set) var count = 0
    var pairs: [(before: AccessibilitySnapshot, after: AccessibilitySnapshot)] = []
    var changed = Set<String>()
    /// Where each changed element with a frame has been.
    var swept: [String: AccessibilitySnapshot.Frame] = [:]

    public init() {}

    mutating func note(_ before: AccessibilitySnapshot, _ after: AccessibilitySnapshot, changed: [(key: String, frames: [AccessibilitySnapshot.Frame])]) {
        count += 1
        pairs.append((before, after))
        if pairs.count > Self.keptPairs { pairs.removeFirst() }
        for (key, frames) in changed {
            self.changed.insert(key)
            let earlier = swept[key].map { [$0] } ?? []
            if let bounds = MovingPart.bounds(of: earlier + frames, within: nil) { swept[key] = bounds }
        }
    }
}

/// How a timed-out `--settled` wait names what kept moving.
public struct MovingReport: Equatable, Sendable {
    /// The flags that leave it out, proven on the wait's own reads; nil when none does and leaves something to wait for.
    public let part: MovingPart?
    /// `panel (20, 200) 300x280`, `Group (900, 0) 40x40, off screen`.
    public let named: String
    /// Every mover is off screen or beneath the page, so the pixels do not show it.
    public let unseen: Bool
}

/// Compares two accessibility snapshots. Each node is keyed by its path of `type#identifier[n]`
/// components, with UUID-shaped identifier text normalised to `<uuid>` and `n` the ordinal among
/// siblings sharing that type and identifier. A shared key changes when its role, subrole, label,
/// value, title, enabled, checked, selected or focused state, or frame (rounded to `framePrecision`)
/// differs. The result is `changed` when the key sets or any shared signature differ outside the
/// volatile keys, and `unknown` when either snapshot has no children to compare. Live keys (`role#identifier[n]`) line a cached tree up with a fresh read, sibling by sibling.
public struct ChangeDetector: Sendable {
    public struct Options: Sendable {
        public var framePrecision: Double
        public var ignoredIdentifiers: Set<String>
        /// Leaves label, value and title out, and a resize along its line of a node whose text changed, so a ticking clock is no change.
        public var ignoreText: Bool
        /// Leaves frames out, so a moving list is no change.
        public var ignoreFrames: Bool

        public init(framePrecision: Double = 1, ignoredIdentifiers: Set<String> = [], ignoreText: Bool = false, ignoreFrames: Bool = false) {
            self.framePrecision = framePrecision
            self.ignoredIdentifiers = ignoredIdentifiers
            self.ignoreText = ignoreText
            self.ignoreFrames = ignoreFrames
        }
    }

    public enum Result: Equatable, Sendable {
        case unknown
        case unchanged
        case changed(summary: String)
    }

    private struct Signature: Equatable {
        let role: String?
        let subrole: String?
        let label: String?
        let value: String?
        let title: String?
        let enabled: Bool?
        let state: UIState
        let frame: [Double]?

        /// Without text and frame, for a live key.
        var structural: Signature {
            Signature(role: role, subrole: subrole, label: nil, value: nil, title: nil, enabled: enabled, state: state, frame: nil)
        }
    }

    private struct Entry {
        let key: String
        let liveKey: String
        let identifier: String?
        let node: AccessibilitySnapshot.Node
        let signature: Signature

        /// Built only for an entry a message names, with a masked element's label as tree output shows it.
        var name: String { ChangeDetector.displayName(node, identifier: identifier) }
        var element: String {
            identifier.map { "\(TerminalText.line(node.type, cap: 64))#\(TerminalText.field($0))" } ?? ChangeDetector.displayName(node, identifier: nil)
        }
    }

    public let options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    public func volatileKeys(_ first: AccessibilitySnapshot, _ second: AccessibilitySnapshot) -> Set<String> {
        let a = Dictionary(uniqueKeysWithValues: entries(first).map { ($0.key, $0.signature) })
        let b = Dictionary(uniqueKeysWithValues: entries(second).map { ($0.key, $0.signature) })
        return Set(a.keys).symmetricDifference(b.keys)
            .union(a.keys.filter { key in b[key].map { $0 != a[key] } ?? false })
    }

    /// The live keys of every node, as `liveTextKeys` and `compare(live:)` name them.
    public func liveKeys(_ snapshot: AccessibilitySnapshot) -> Set<String> {
        Set(entries(snapshot).map(\.liveKey))
    }

    /// The share of live keys two reads have in common, from 0 to 1; 1 when both are empty.
    public func sharedKeyFraction(_ first: AccessibilitySnapshot, _ second: AccessibilitySnapshot) -> Double {
        let a = liveKeys(first)
        let b = liveKeys(second)
        guard let larger = [a.count, b.count].max(), larger > 0 else { return 1 }
        return Double(a.intersection(b).count) / Double(larger)
    }

    /// Live keys whose label, value or title differ, whatever the text options say; siblings are lined up by role and id, and each key is the second read's.
    public func liveTextKeys(_ first: AccessibilitySnapshot, _ second: AccessibilitySnapshot) -> Set<String> {
        var keys = Set<String>()
        func visit(_ old: [AccessibilitySnapshot.Node], _ new: [AccessibilitySnapshot.Node], parentKey: String) {
            let before = liveSiblings(old, parentKey: parentKey)
            let after = liveSiblings(new, parentKey: parentKey)
            // An added or removed row pairs with nothing, so neither the rows around it nor their later keys are taken for one another.
            let pairs = Self.alignment(before.map(\.component), after.map(\.component)) { Self.sameText(before[$0].node, after[$1].node) }
            for (index, otherIndex) in pairs {
                let (previous, current) = (before[index], after[otherIndex])
                if !Self.sameText(previous.node, current.node) {
                    keys.insert(current.key)
                }
                visit(previous.node.children, current.node.children, parentKey: current.key)
            }
        }
        visit(first.roots, second.roots, parentKey: "")
        return keys
    }

    private static func sameText(_ a: AccessibilitySnapshot.Node, _ b: AccessibilitySnapshot.Node) -> Bool {
        a.label == b.label && a.value == b.value && a.title == b.title
    }

    /// Past this many cells, two sibling lists that differ are not lined up, so nothing beneath them is learnt.
    static let maximumAlignmentCells = 1_000_000

    /// Index pairs of a longest common subsequence of `a` and `b`, choosing among equally long ones the most pairs with `unchanged` text.
    static func alignment(_ a: [String], _ b: [String], unchanged: (Int, Int) -> Bool) -> [(Int, Int)] {
        if a == b {
            return a.indices.map { ($0, $0) }
        }
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start], unchanged(start, start) {
            start += 1
        }
        var (endA, endB) = (a.count, b.count)
        while endA > start, endB > start, a[endA - 1] == b[endB - 1], unchanged(endA - 1, endB - 1) {
            (endA, endB) = (endA - 1, endB - 1)
        }
        let (rows, columns) = (endA - start, endB - start)
        let prefix = (0..<start).map { ($0, $0) }
        let suffix = (0..<(a.count - endA)).map { (endA + $0, endB + $0) }
        guard rows > 0, columns > 0 else { return prefix + suffix }
        guard rows * columns <= maximumAlignmentCells else { return [] }
        // One more pair outweighs any number of unchanged texts.
        let pairWeight = min(rows, columns) + 1
        func gain(_ row: Int, _ column: Int) -> Int? {
            guard a[start + row] == b[start + column] else { return nil }
            return pairWeight + (unchanged(start + row, start + column) ? 1 : 0)
        }
        let width = columns + 1
        var best = [Int](repeating: 0, count: (rows + 1) * width)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                let skip = max(best[(row + 1) * width + column], best[row * width + column + 1])
                best[row * width + column] = gain(row, column).map { max(skip, best[(row + 1) * width + column + 1] + $0) } ?? skip
            }
        }
        var middle: [(Int, Int)] = []
        var (row, column) = (0, 0)
        while row < rows, column < columns {
            if let gain = gain(row, column), best[row * width + column] == best[(row + 1) * width + column + 1] + gain {
                middle.append((start + row, start + column))
                (row, column) = (row + 1, column + 1)
            } else if best[(row + 1) * width + column] >= best[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return prefix + middle + suffix
    }

    /// The elements on `live` keys whose text differs between the reads, named as change summaries name them.
    public func liveChanges(_ before: AccessibilitySnapshot, _ after: AccessibilitySnapshot, live: Set<String>) -> [String] {
        guard !live.isEmpty else { return [] }
        let changed = liveTextKeys(before, after).intersection(live)
        return entries(after).filter { changed.contains($0.liveKey) }.map(\.name)
    }

    /// The elements on type `keys` that are added, removed or changed between the reads, named as change summaries name them.
    public func keyChanges(_ before: AccessibilitySnapshot, _ after: AccessibilitySnapshot, keys: Set<String>) -> [String] {
        guard !keys.isEmpty else { return [] }
        let old = Dictionary(entries(before).filter { keys.contains($0.key) }.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let new = entries(after).filter { keys.contains($0.key) }
        let changed = new.filter { entry in old[entry.key].map { $0.signature != entry.signature } ?? true }.map(\.name)
        let newKeys = Set(new.map(\.key))
        return changed + old.values.filter { !newKeys.contains($0.key) }.map(\.name).sorted()
    }

    /// The frames of the nodes on type `keys` or `live` keys in `snapshot`, for leaving their pixels out.
    public func frames(of keys: Set<String>, live: Set<String> = [], in snapshot: AccessibilitySnapshot) -> [AccessibilitySnapshot.Frame] {
        guard !keys.isEmpty || !live.isEmpty else { return [] }
        return entries(snapshot).filter { keys.contains($0.key) || live.contains($0.liveKey) }.compactMap(\.node.frame)
    }

    /// `tree` with the label and value of every node on a `live` key replaced by one placeholder, so a tree diff passes over its text.
    public func maskingLive(_ tree: UITree, live: Set<String>) -> UITree {
        guard !live.isEmpty else { return tree }
        func mask(_ nodes: [UINode], parentKey: String) -> [UINode] {
            var ordinals: [String: Int] = [:]
            return nodes.map { node in
                let identifier = Self.normalisedIdentifier(node.id)
                if let identifier, options.ignoredIdentifiers.contains(identifier) { return node }
                let component = "\(node.role.rawValue)#\(identifier ?? "")"
                let ordinal = ordinals[component, default: 0]
                ordinals[component] = ordinal + 1
                let key = "\(parentKey)/\(component)[\(ordinal)]"
                var masked = node
                if live.contains(key) {
                    masked.label = node.label.map { _ in Self.livePlaceholder }
                    masked.value = node.value.map { _ in Self.livePlaceholder }
                }
                masked.children = mask(node.children, parentKey: key)
                return masked
            }
        }
        var masked = tree
        masked.roots = mask(tree.roots, parentKey: "")
        return masked
    }

    static let livePlaceholder = "(live)"

    /// Adds a pair of reads that differ to `log`.
    public func note(_ before: AccessibilitySnapshot, _ after: AccessibilitySnapshot, in log: inout MoveLog) {
        let old = Dictionary(entries(before).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let new = entries(after)
        let newKeys = Set(new.map(\.key))
        let changed = new.filter { entry in old[entry.key].map { describeDifference(from: $0, to: entry, live: false) != nil } ?? true }.map { entry in
            (key: entry.key, frames: [entry.node.frame, old[entry.key]?.node.frame].compactMap { $0 })
        } + old.values.filter { !newKeys.contains($0.key) }.map { (key: $0.key, frames: [$0.node.frame].compactMap { $0 }) }
        log.note(before, after, changed: changed)
    }

    /// What changed between the reads, as the flags that leave it out; nil when none would.
    public func movingPart(_ before: AccessibilitySnapshot, _ after: AccessibilitySnapshot) -> MovingPart? {
        var log = MoveLog()
        note(before, after, in: &log)
        return moving(log)?.part
    }

    /// What `log` saw moving, named for a person, with the flags that leave it out when any do: the nearest element holding every change that has an id a command line can carry, else a rectangle around the changes, else one flag per mover. Each is proven on the reads themselves, so what a timeout prints lets the next wait pass.
    public func moving(_ log: MoveLog) -> MovingReport? {
        guard let last = log.pairs.last, !log.changed.isEmpty else { return nil }
        let new = entries(last.after)
        let newByKey = Dictionary(new.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let keys = log.changed.sorted()
        let movers = keys.filter { key in !Self.ancestors(of: key).dropFirst().contains(where: log.changed.contains) }
        // A mover gone from the latest read is named from the reads that held it.
        var known = newByKey
        for pair in log.pairs.reversed() where movers.prefix(3).contains(where: { known[$0] == nil }) {
            for snapshot in [pair.after, pair.before] {
                for entry in entries(snapshot) where known[entry.key] == nil { known[entry.key] = entry }
            }
        }
        let screen = last.after.roots.compactMap(\.frame).max { $0.width * $0.height < $1.width * $1.height }
        let covers = coverers(of: Set(movers), in: last.after, screen: screen)

        let usableID = { (key: String) -> String? in
            guard let holder = newByKey[key], let id = holder.identifier, MovingPart.fitsCommandLine(id), !Self.isMasked(holder.node) else { return nil }
            return id
        }
        let rectangles = { (frames: [AccessibilitySnapshot.Frame]) -> [MovingPart] in
            let around = [MovingPart.bounds(of: frames, within: screen), MovingPart.bounds(of: frames, within: nil)].compactMap { $0 }
            return around.map { MovingPart.region(PointRegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }
        }
        var candidates = Self.sharedAncestors(of: keys).compactMap(usableID).map(MovingPart.id)
        let sweep = keys.compactMap { log.swept[$0] }
        let shownArea = MovingPart.bounds(of: sweep, within: screen).map { $0.width * $0.height } ?? 0
        let around = shownArea < (screen.map { $0.width * $0.height * MovingPart.mostOfScreen } ?? .infinity) ? rectangles(sweep) : []
        // A rectangle over something still would stop the wait watching it, so one flag per mover comes first.
        let stillInside = new.filter { entry in
            !Self.ancestors(of: entry.key).contains(where: log.changed.contains)
        }
        let sparing = around.filter { part in
            !stillInside.contains { entry in entry.node.frame.map { frame in part.regions.contains(where: frame.isHalfInside) } ?? false }
        }
        candidates += sparing
        if movers.count > 1, movers.count <= MovingPart.mostFlags {
            for clipped in [true, false] {
                let flags = movers.compactMap { key -> MovingPart? in
                    // An id holding another mover is the page around them, which the proof below would refuse.
                    let own = Self.ancestors(of: key).prefix { holder in !movers.contains { $0 != key && $0.hasPrefix(holder + "/") } }
                    if let id = own.compactMap(usableID).first { return .id(id) }
                    guard let frame = log.swept[key] else { return nil }
                    return clipped ? rectangles([frame]).first : rectangles([frame]).last
                }
                if flags.count == movers.count { candidates.append(.parts(flags)) }
            }
        }
        candidates += around
        let part = candidates.first { leavesOut($0, in: log, screen: screen) }

        let shown = movers.prefix(3).map { key in Self.described(known[key], at: log.swept[key], latest: newByKey[key]?.node.frame, cover: covers[key], screen: screen) }
        let more = movers.count > shown.count ? ", and \(movers.count - shown.count) more" : ""
        let unseen = movers.allSatisfy { key in
            guard let frame = newByKey[key]?.node.frame ?? log.swept[key] else { return false }
            return covers[key] != nil || !Self.isOnScreen(frame, screen)
        }
        return MovingReport(part: part, named: shown.joined(separator: "; ") + more, unseen: unseen)
    }

    /// True when `part` stills every read kept, and what it takes away leaves something to wait for.
    private func leavesOut(_ part: MovingPart, in log: MoveLog, screen: AccessibilitySnapshot.Frame?) -> Bool {
        var wider = options
        wider.ignoredIdentifiers.formUnion(part.ids.compactMap(Self.normalisedIdentifier))
        let detector = ChangeDetector(options: wider)
        let regions = part.regions
        for pair in log.pairs where detector.compare(pair.before.leavingOut(regions), pair.after.leavingOut(regions)) != .unchanged {
            return false
        }
        guard let screen, let last = log.pairs.last else { return true }
        let area = { (frames: [AccessibilitySnapshot.Frame]) -> Double in
            MovingPart.bounds(of: frames, within: screen).map { $0.width * $0.height } ?? 0
        }
        let whole = screen.width * screen.height
        let gone = entries(last.after).filter { entry in part.ids.contains { Self.normalisedIdentifier($0) == entry.identifier } }.compactMap(\.node.frame)
        let cut = max(area(gone), regions.map { area([AccessibilitySnapshot.Frame(x: $0.x, y: $0.y, width: $0.width, height: $0.height)]) }.max() ?? 0)
        guard cut >= whole * MovingPart.mostOfScreen else { return true }
        let kept = last.after.leavingOut(regions).roots.flatMap { root in detector.entries(AccessibilitySnapshot(roots: root.children)) }.compactMap(\.node.frame)
        return kept.contains { area([$0]) >= whole * (1 - MovingPart.mostOfScreen) }
    }

    /// `key` and the keys above it, nearest first.
    private static func ancestors(of key: String) -> [String] {
        var keys = [key]
        var rest = key
        while let cut = rest.range(of: "]/", options: .backwards) {
            rest = String(rest[..<cut.lowerBound]) + "]"
            keys.append(rest)
        }
        return keys
    }

    /// For each of `keys` on the screen, the first later sibling, of it or anything above it, whose children sit over all of what shows of it.
    private func coverers(of keys: Set<String>, in snapshot: AccessibilitySnapshot, screen: AccessibilitySnapshot.Frame?) -> [String: AccessibilitySnapshot.Node] {
        var found: [String: AccessibilitySnapshot.Node] = [:]
        func walk(_ nodes: [AccessibilitySnapshot.Node], parentKey: String, parentLiveKey: String, above: [AccessibilitySnapshot.Node]) {
            let siblings = liveSiblings(nodes, parentKey: parentLiveKey)
            var ordinals: [String: Int] = [:]
            for (index, sibling) in siblings.enumerated() {
                let component = "\(sibling.node.type)#\(sibling.identifier ?? "")"
                let ordinal = ordinals[component, default: 0]
                ordinals[component] = ordinal + 1
                let key = "\(parentKey)/\(component)[\(ordinal)]"
                let over = siblings[(index + 1)...].map(\.node) + above
                if keys.contains(key), let frame = sibling.node.frame, let shown = MovingPart.bounds(of: [frame], within: screen) {
                    found[key] = over.first { node in
                        guard !node.children.isEmpty, let cover = node.frame else { return false }
                        return cover.x <= shown.x && cover.y <= shown.y && cover.x + cover.width >= shown.x + shown.width && cover.y + cover.height >= shown.y + shown.height
                    }
                }
                walk(sibling.node.children, parentKey: key, parentLiveKey: sibling.key, above: over)
            }
        }
        walk(snapshot.roots, parentKey: "", parentLiveKey: "", above: [])
        return found
    }

    private static func isOnScreen(_ frame: AccessibilitySnapshot.Frame, _ screen: AccessibilitySnapshot.Frame?) -> Bool {
        guard let screen else { return true }
        return MovingPart.bounds(of: [frame], within: screen) != nil
    }

    /// `panel (20, 200) 300x280`, with where it is when that is not plainly on the screen.
    private static func described(_ entry: Entry?, at swept: AccessibilitySnapshot.Frame?, latest: AccessibilitySnapshot.Frame?, cover: AccessibilitySnapshot.Node?, screen: AccessibilitySnapshot.Frame?) -> String {
        let name = entry?.name ?? "An element"
        guard let frame = latest ?? swept else { return name }
        let whole = { (value: Double) in Int(value.rounded()) }
        let place = "\(name) (\(whole(frame.x)), \(whole(frame.y))) \(whole(frame.width))x\(whole(frame.height))"
        if !isOnScreen(frame, screen) { return "\(place), off screen" }
        if let cover { return "\(place), beneath \(displayName(cover, identifier: normalisedIdentifier(cover.identifier)))" }
        return place
    }

    /// The keys every one of `keys` sits at or under, deepest first.
    private static func sharedAncestors(of keys: [String]) -> [String] {
        // Each key ends `[n]`, so the components split cleanly at `]/`.
        let separator = "]/"
        let paths = keys.map { $0.dropLast().components(separatedBy: separator) }
        guard let first = paths.first else { return [] }
        let depth = paths.dropFirst().reduce(first.count) { depth, path in min(depth, zip(first, path).prefix { $0 == $1 }.count) }
        guard depth > 0 else { return [] }
        return (1...depth).reversed().map { first.prefix($0).joined(separator: separator) + "]" }
    }

    /// What a comparison of `snapshot` can see: any root, and anything under one, once the ignored identifiers are left out.
    public func coverage(_ snapshot: AccessibilitySnapshot) -> (roots: Bool, elements: Bool) {
        let roots = liveSiblings(snapshot.roots, parentKey: "")
        return (!roots.isEmpty, roots.contains { !liveSiblings($0.node.children, parentKey: "").isEmpty })
    }

    public func compare(
        _ before: AccessibilitySnapshot,
        _ after: AccessibilitySnapshot,
        ignoring volatile: Set<String> = [],
        live: Set<String> = []
    ) -> Result {
        guard before.isKnown, after.isKnown else { return .unknown }
        let beforeEntries = entries(before).filter { !volatile.contains($0.key) }
        let afterEntries = entries(after).filter { !volatile.contains($0.key) }
        let beforeByKey = Dictionary(uniqueKeysWithValues: beforeEntries.map { ($0.key, $0) })
        let afterKeys = Set(afterEntries.map(\.key))

        for entry in afterEntries {
            guard let previous = beforeByKey[entry.key] else {
                return .changed(summary: "element added: \(entry.element)")
            }
            if let difference = describeDifference(from: previous, to: entry, live: live.contains(entry.liveKey)) {
                return .changed(summary: difference)
            }
        }
        if let removed = beforeEntries.first(where: { !afterKeys.contains($0.key) }) {
            return .changed(summary: "element removed: \(removed.element)")
        }
        return .unchanged
    }

    private func entries(_ snapshot: AccessibilitySnapshot) -> [Entry] {
        var result: [Entry] = []
        flatten(snapshot.roots, parentKey: "", parentLiveKey: "", into: &result)
        return result
    }

    /// Each node not ignored, with its live component (`role#identifier`) and live key among its siblings.
    private func liveSiblings(
        _ nodes: [AccessibilitySnapshot.Node], parentKey: String
    ) -> [(node: AccessibilitySnapshot.Node, identifier: String?, component: String, key: String)] {
        var ordinals: [String: Int] = [:]
        return nodes.compactMap { node in
            let identifier = Self.normalisedIdentifier(node.identifier)
            if let identifier, options.ignoredIdentifiers.contains(identifier) { return nil }
            let component = "\(node.uiRole ?? node.type)#\(identifier ?? "")"
            let ordinal = ordinals[component, default: 0]
            ordinals[component] = ordinal + 1
            return (node, identifier, component, "\(parentKey)/\(component)[\(ordinal)]")
        }
    }

    private func flatten(_ nodes: [AccessibilitySnapshot.Node], parentKey: String, parentLiveKey: String, into result: inout [Entry]) {
        var ordinals: [String: Int] = [:]
        for (node, identifier, _, liveKey) in liveSiblings(nodes, parentKey: parentLiveKey) {
            let component = "\(node.type)#\(identifier ?? "")"
            let ordinal = ordinals[component, default: 0]
            ordinals[component] = ordinal + 1
            let key = "\(parentKey)/\(component)[\(ordinal)]"
            result.append(Entry(
                key: key,
                liveKey: liveKey,
                identifier: identifier,
                node: node,
                signature: signature(node)
            ))
            flatten(node.children, parentKey: key, parentLiveKey: liveKey, into: &result)
        }
    }

    private func signature(_ node: AccessibilitySnapshot.Node) -> Signature {
        let precision = options.framePrecision > 0 ? options.framePrecision : 1
        let frame = node.frame.map { frame in
            [frame.x, frame.y, frame.width, frame.height].map { ($0 / precision).rounded() }
        }
        let text = !options.ignoreText
        return Signature(
            role: node.role,
            subrole: node.subrole,
            label: text ? node.label : nil,
            value: text ? node.value : nil,
            title: text ? node.title : nil,
            enabled: node.enabled,
            state: node.state,
            frame: options.ignoreFrames ? nil : frame
        )
    }

    private func describeDifference(from before: Entry, to after: Entry, live: Bool) -> String? {
        let textMoved = options.ignoreText
            && (before.node.label != after.node.label || before.node.value != after.node.value || before.node.title != after.node.title)
            && Self.resizedAlongItsLine(before.signature.frame, after.signature.frame)
        let a = live || textMoved ? before.signature.structural : before.signature
        let b = live || textMoved ? after.signature.structural : after.signature
        guard a != b else { return nil }
        let name = after.name
        if a.value != b.value, before.node.isSecure || after.node.isSecure { return "value of \(name) changed (secure field)" }
        let masked = Self.isMasked(before.node) || Self.isMasked(after.node)
        if a.value != b.value { return masked ? "value of \(name) changed (masked)" : "value of \(name) changed from \(Self.quoted(a.value)) to \(Self.quoted(b.value))" }
        if a.label != b.label { return masked ? "label of \(name) changed (masked)" : "label of \(name) changed from \(Self.quoted(a.label)) to \(Self.quoted(b.label))" }
        if a.title != b.title { return masked ? "title of \(name) changed (masked)" : "title of \(name) changed from \(Self.quoted(a.title)) to \(Self.quoted(b.title))" }
        if a.enabled != b.enabled { return "\(name) became \(b.enabled == true ? "enabled" : "disabled")" }
        if a.state.checked != b.state.checked { return "checked state of \(name) changed" }
        if a.state.selected != b.state.selected { return "selected state of \(name) changed" }
        if a.state.focused != b.state.focused { return "focused state of \(name) changed" }
        if a.frame != b.frame { return "\(name) moved or resized" }
        if a.role != b.role || a.subrole != b.subrole { return "role of \(name) changed" }
        return nil
    }

    /// As a right-aligned number's frame follows its digits. Leaving its line is a move, as when iOS lists a chart's bars by height and each place in the tree takes a new label and frame.
    private static func resizedAlongItsLine(_ before: [Double]?, _ after: [Double]?) -> Bool {
        guard let before, let after else { return true }
        return before[1] == after[1] && before[3] == after[3] && (before[0] == after[0] || before[2] != after[2])
    }

    /// Whether a masked id or label names the element, so a summary names it without its text.
    private static func isMasked(_ node: AccessibilitySnapshot.Node) -> Bool {
        let trimmed = { (text: String?) -> String? in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return OutputMasks.current.mask.hides(id: trimmed(node.identifier), label: trimmed(node.label))
    }

    /// The JSON `node` value: bare, since JSON strings carry their own escaping and the `untrusted` list names the field.
    fileprivate static func displayName(_ node: AccessibilitySnapshot.Node, identifier: String?) -> String {
        if let identifier { return TerminalText.bareOrQuoted(identifier) }
        if let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return "\(TerminalText.line(node.type, cap: 64)) \(TerminalText.quoted(OutputMasks.current.mask.shownLabel(label, id: node.identifier)))"
        }
        return TerminalText.line(node.type, cap: 64)
    }

    private static func quoted(_ value: String?) -> String {
        value.map { TerminalText.quoted($0) } ?? "nothing"
    }

    static func normalisedIdentifier(_ identifier: String?) -> String? {
        guard let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return uuidPattern.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "<uuid>")
    }

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    )
}
