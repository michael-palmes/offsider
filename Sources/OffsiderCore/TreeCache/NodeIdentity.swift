import Foundation

/// How a node is named across two reads, for `describe-ui --diff`, verify changes and the transition guard.
public enum NodeIdentity {
    public static let originGrid = 4.0

    /// `#id` with UUID-shaped text normalised, else `role "label" @x,y` on a 4 pt grid; nil with neither id nor label.
    public static func baseKey(_ node: UINode) -> String? {
        if let id = ChangeDetector.normalisedIdentifier(node.id) {
            return "#" + id
        }
        guard let label = node.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var quoted = ""
        OrderedJSON.writeString(label, to: &quoted)
        let origin = node.frame.map { "@\(grid($0.x)),\(grid($0.y))" } ?? "@none"
        return "\(node.role.rawValue) \(quoted) \(origin)"
    }

    /// One key per node in document order; a repeated key gets `~2`, `~3` from its second use.
    public static func keys(_ nodes: [UINode]) -> [String?] {
        var uses: [String: Int] = [:]
        return nodes.map { node in
            guard let base = baseKey(node) else { return nil }
            let count = uses[base, default: 0] + 1
            uses[base] = count
            return count == 1 ? base : "\(base)~\(count)"
        }
    }

    /// The same element for the transition guard: role, id and label agree; value is left out because it changes with state.
    public static func isGuardMatch(_ lhs: UINode, _ rhs: UINode) -> Bool {
        lhs.role == rhs.role && lhs.id == rhs.id && lhs.label == rhs.label
    }

    /// The candidate whose frame centre is nearest `centre`; nodes without a frame are skipped.
    public static func nearest(_ candidates: [UINode], to centre: UIPoint) -> UINode? {
        candidates
            .compactMap { node in node.frame.map { (node, $0.center) } }
            .min { distance($0.1, centre) < distance($1.1, centre) }?
            .0
    }

    private static func distance(_ lhs: UIPoint, _ rhs: UIPoint) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func grid(_ value: Double) -> String {
        OrderedJSON.formatNumber((value / originGrid).rounded() * originGrid)
    }
}
