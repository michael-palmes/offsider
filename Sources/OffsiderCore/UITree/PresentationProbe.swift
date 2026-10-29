import Foundation

/// What one read at the screen's centre shows that the tree does not.
public struct PresentationFinding: Equatable, Sendable {
    public var presented: UITreeContext.Presented?
    public var staleFrame: UITreeContext.StaleFrame?

    public init(presented: UITreeContext.Presented? = nil, staleFrame: UITreeContext.StaleFrame? = nil) {
        self.presented = presented
        self.staleFrame = staleFrame
    }

    /// A wait's or assert's last reason with what the read found: a likely stale frame after `off screen at`, and what is presented.
    public func explaining(_ reason: String) -> String {
        var explained = reason
        if let staleFrame, reason.hasPrefix("off screen at") {
            explained += " (likely a stale frame: the screen's centre is inside \(staleFrame.name); check a screenshot)"
        }
        if let presented {
            explained += "; presented: \(presented.summary)"
        }
        return explained
    }
}

extension UITree {
    /// The tree with what describe-ui's read at the screen's centre found; a system prompt found at the same middle already names what is over the app, so it is not named twice.
    public mutating func apply(_ finding: PresentationFinding) {
        presented = systemPrompt == nil ? finding.presented : nil
        staleFrame = finding.staleFrame
    }
}

/// Compares one element read at the screen's centre with the whole-app tree: a view drawn by another process, or one the tree does not list, is presented; a screen-sized node the tree places off screen that holds the read has a stale frame.
public enum PresentationProbe {
    static let labelLimit = 40
    /// Of the viewport on each axis, for a node to count as screen-sized.
    static let screenShare = 0.8

    /// The application's centre, where the probe reads; nil without a usable frame.
    public static func point(in tree: UITree) -> UIPoint? {
        guard let frame = tree.applicationFrame, frame.width > 0, frame.height > 0 else { return nil }
        return frame.center
    }

    /// `processPath` gives a pid's executable path, of which only the file name is kept.
    public static func finding(in tree: UITree, hit: UINode?, processPath: (Int) -> String?) -> PresentationFinding {
        guard let hit else { return PresentationFinding() }
        let flat = tree.roots.flatMap { $0.flattened() }
        let placed = place(hit, in: flat)
        let host = (tree.roots.first { $0.role == .application } ?? tree.roots.first)?.iosPID
        var finding = PresentationFinding()
        let foreign = hit.iosPID != nil && host != nil && hit.iosPID != host
        if foreign || (placed == nil && isUnlisted(hit, in: flat)) {
            let process = hit.iosPID.flatMap(processPath).map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            if !(foreign && isHostedWebContent(hit, process: process, in: flat, hostPID: host, viewport: tree.viewport)) {
                finding.presented = UITreeContext.Presented(label: shownLabel(of: hit), role: hit.role, process: process)
            }
        }
        if let placed, let viewport = tree.viewport {
            finding.staleFrame = staleFrame(holding: placed, in: tree.roots, viewport: viewport)
        }
        return finding
    }

    /// WebKit draws an app's own web view, such as a widget inside a form, from its web content process: a container of the app's smaller than the screen holds it.
    static func isHostedWebContent(_ hit: UINode, process: String?, in flat: [UINode], hostPID: Int?, viewport: UIFrame?) -> Bool {
        guard let process, process.hasPrefix(webContentProcess), let hostPID, let frame = hit.frame, let viewport else { return false }
        return flat.contains { node in
            guard node.iosPID == hostPID, [.group, .other, .scrollView].contains(node.role), let host = node.frame else { return false }
            let screenSized = host.width >= screenShare * viewport.width && host.height >= screenShare * viewport.height
            return !screenSized && host.encloses(frame, tolerance: 1)
        }
    }

    static let webContentProcess = "com.apple.WebKit.WebContent"

    /// A labelled or identified hit no element of the tree shares, wherever it lies; an unlabelled container or a row that scrolled between the two reads says nothing.
    static func isUnlisted(_ hit: UINode, in flat: [UINode]) -> Bool {
        guard hit.normalizedLabel != nil || hit.normalizedID != nil else { return false }
        return !flat.contains { $0.role == hit.role && $0.id == hit.id && $0.label == hit.label }
    }

    /// The label with secrets masked, cut to 40 characters; never a value, and nothing from a secure field.
    static func shownLabel(of node: UINode) -> String? {
        guard !node.isSecure, let label = node.normalizedLabel else { return nil }
        return SelectorText.truncated(OutputMasks.current.mask.masked(label, id: node.normalizedID) ?? LogRedactor.redact(label).text, limit: labelLimit)
    }

    /// The hit as an element of the tree: read again unchanged, moved by up to a point, or with its label ticked in place.
    static func place(_ hit: UINode, in flat: [UINode]) -> UINode? {
        flat.first { $0.isSameElement(as: hit) }
            ?? flat.first { $0.isLoosely(hit) }
            ?? flat.first { node in
                guard node.role == hit.role, node.id == hit.id, let mine = node.frame, let theirs = hit.frame else { return false }
                return mine.isWithinTolerance(of: theirs) || (hit.normalizedID != nil && node.label == hit.label)
            }
    }

    /// The outermost screen-sized node wholly off screen that holds labelled elements and `placed`, preferring one with an id.
    static func staleFrame(holding placed: UINode, in roots: [UINode], viewport: UIFrame) -> UITreeContext.StaleFrame? {
        let stale = roots.flatMap { $0.flattened() }.filter { node in
            guard let frame = node.frame, frame.width >= screenShare * viewport.width, frame.height >= screenShare * viewport.height,
                  OffScreenSide.of(frame, in: viewport) != nil else { return false }
            let inside = node.flattened()
            return inside.dropFirst().contains { $0.normalizedLabel != nil } && inside.contains { $0.isSameElement(as: placed) }
        }
        guard let chosen = stale.first(where: { $0.normalizedID != nil }) ?? stale.first, let frame = chosen.frame else { return nil }
        let label = chosen.normalizedLabel.map { OutputMasks.current.mask.masked($0, id: chosen.normalizedID) ?? LogRedactor.redact($0).text }
        return UITreeContext.StaleFrame(id: chosen.normalizedID, label: label.map { SelectorText.truncated($0, limit: labelLimit) }, frame: frame)
    }
}
