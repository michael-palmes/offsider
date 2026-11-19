import Foundation

/// Where the tree cache last saw an element a mask names, while an iOS modal hides it from every read: painted, never proven.
public enum RememberedMasks {
    /// What one capture paints from memory, by kind, and what it names (`--mask-id profile-email`, `an email address`).
    public struct Found: Equatable, Sendable {
        public var frames: [MaskKind: [UIFrame]] = [:]
        public var names: [String] = []

        public init(frames: [MaskKind: [UIFrame]] = [:], names: [String] = []) {
            self.frames = frames
            self.names = names
        }

        public var isEmpty: Bool { frames.values.allSatisfy(\.isEmpty) }
    }

    /// The last tree read with no modal over the app, when `current` shows the same app on the same screen and that memory is fresh.
    public static func tree(in record: TreeCacheRecord?, current: UITree, screen: UIScreenInfo?, now: Date, statusBar: Double) -> UITree? {
        guard let record, record.platform == current.platform, let uncovered = record.uncovered(statusBar: statusBar),
              record.matches(appFrame: current.applicationFrame, screen: screen) else { return nil }
        guard uncovered.isFresh(now: now), uncovered.fits(current) else { return nil }
        return UITree(platform: record.platform, device: record.device, roots: uncovered.roots)
    }

    /// What `plan` names in `remembered` (`selected` for id and label selectors) that `current` no longer lists, under its modal; a value the cache hid matches text and email masks.
    public static func targets(
        plan: MaskPlan, selected: [(kind: MaskKind, name: String, nodes: [UINode])], remembered: UITree, current: UITree, region: UIFrame
    ) throws -> Found {
        let listed = current.roots.flatMap { $0.flattened() }
        func hidden(_ nodes: [UINode]) -> [UIFrame] {
            nodes.compactMap { node in
                guard let frame = node.frame, frame.width > 0, frame.height > 0, frame.intersection(region) != nil,
                      !listed.contains(where: { NodeIdentity.isGuardMatch($0, node) }) else { return nil }
                return frame
            }
        }
        var found = Found()
        func add(_ nodes: [UINode], as kind: MaskKind, name: String) {
            let frames = hidden(nodes)
            guard !frames.isEmpty else { return }
            found.frames[kind, default: []] += frames
            if !found.names.contains(name) { found.names.append(name) }
        }
        for selector in selected {
            add(selector.nodes, as: selector.kind, name: selector.name)
        }
        for pattern in plan.texts {
            let regex = try MaskPlan.compile(pattern)
            add(leafMost(remembered.roots) { matches(regex, $0) || $0.contains(LogRedactor.marker) }, as: .text, name: "--mask-text \(pattern)")
        }
        if plan.emails {
            let regex = try MaskPlan.compile(PersonalData.emailPattern)
            add(leafMost(remembered.roots) { matches(regex, $0) || $0.contains(LogRedactor.emailMarker) }, as: .emails, name: "an email address")
        }
        return found
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// As a tree mask matches: a node whose descendant matches is left to the descendant.
    private static func leafMost(_ nodes: [UINode], _ test: (String) -> Bool) -> [UINode] {
        nodes.flatMap { node -> [UINode] in
            let below = leafMost(node.children, test)
            if !below.isEmpty { return below }
            return node.searchableText.contains(where: test) ? [node] : []
        }
    }
}
