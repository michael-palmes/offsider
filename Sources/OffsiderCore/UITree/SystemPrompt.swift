import Foundation

/// A prompt another process draws over an iOS app, such as AutoFill's Save Password?: the app's tree holds only the empty host UIKit adds for it, so only a point read reaches it.
public struct SystemPrompt: Equatable, Sendable {
    /// Text the probe reached, such as `Save Password?`.
    public var title: String?
    /// The process that draws it, such as `SafariViewService`.
    public var process: String?
    public var pid: Int

    public init(title: String?, process: String?, pid: Int) {
        self.title = title
        self.process = process
        self.pid = pid
    }

    /// The window `describe-ui`'s context names: a system window titled by the prompt and owned by its process.
    public var window: UITreeContext.Window {
        UITreeContext.Window(title: title, kind: .system, package: process)
    }

    /// `the system prompt "Save Password?" from SafariViewService`.
    public var summary: String {
        var parts = ["the system prompt"]
        if let title {
            parts.append(TerminalText.quoted(SelectorText.truncated(title)))
        }
        parts.append("from \(process.map { TerminalText.bareOrQuoted($0) } ?? "pid \(pid)")")
        return parts.joined(separator: " ")
    }

    /// Windows over the app's first that look like that host: nothing labelled, named or actionable, no keyboard, and a container larger than the screen.
    public static func hosts(in tree: UITree) -> [(index: Int, window: UINode)] {
        guard tree.platform == .ios, let viewport = tree.viewport else { return [] }
        return windows(in: tree.roots).enumerated().dropFirst().filter { isHost($0.element, viewport: viewport) }.map { ($0.offset, $0.element) }
    }

    /// True when a host sits in a window over the one holding `target`.
    public static func hasHost(over target: UINode, in tree: UITree) -> Bool {
        let hosts = hosts(in: tree)
        guard let last = hosts.last else { return false }
        let holding = windows(in: tree.roots).firstIndex { $0.flattened().contains { $0.isSameElement(as: target) } } ?? 0
        return last.index > holding
    }

    /// True when `hit` comes from a process none of `roots` come from; false when the tree carries no pids.
    public static func isForeign(_ hit: UINode, in roots: [UINode]) -> Bool {
        guard let pid = hit.iosPID else { return false }
        let pids = pids(in: roots)
        return !pids.isEmpty && !pids.contains(pid)
    }

    /// The processes the tree's iOS elements come from.
    public static func pids(in roots: [UINode]) -> Set<Int> {
        Set(roots.flatMap { $0.flattened() }.compactMap(\.iosPID))
    }

    /// A hit's label when it is text or a heading, as an alert's title and message are.
    public static func title(of hit: UINode) -> String? {
        guard hit.role == .text || hit.role == .header else { return nil }
        return hit.normalizedLabel
    }

    /// An alert in a tree another process shows in the app's place, such as SpringBoard's permission request: the topmost titled box smaller than the screen that holds buttons.
    public static func alert(in tree: UITree) -> (title: String, buttons: [String])? {
        guard tree.platform == .ios, let viewport = tree.viewport else { return nil }
        return tree.roots.flatMap { $0.flattened() }.reversed().lazy.compactMap { node -> (title: String, buttons: [String])? in
            guard node.role != .application, node.role != .button, let title = node.normalizedLabel, let frame = node.frame,
                  frame.width < viewport.width - 1 || frame.height < viewport.height - 1 else { return nil }
            let buttons = node.flattened().filter { $0.role == .button }.compactMap(\.normalizedLabel)
            return buttons.isEmpty ? nil : (title, buttons)
        }.first
    }

    /// Where `describe-ui` looks: the middle of the screen, where an alert's text sits.
    public static func probePoint(in viewport: UIFrame) -> UIPoint {
        viewport.center
    }

    /// The iOS application root's windows; on iOS UIKit lists each window as a child of the application.
    private static func windows(in roots: [UINode]) -> [UINode] {
        roots.flatMap { $0.role == .application ? $0.children : [$0] }
    }

    private static func isHost(_ window: UINode, viewport: UIFrame) -> Bool {
        let nodes = window.flattened()
        let bare = nodes.allSatisfy { node in
            node.role != .keyboard && !node.isActionable && node.normalizedLabel == nil && node.normalizedID == nil && node.normalizedValue == nil
        }
        guard bare else { return false }
        // The remote view reports twice the screen's size on an iOS 27 simulator.
        return nodes.contains { node in
            guard let frame = node.frame else { return false }
            return frame.width > viewport.width + 1 || frame.height > viewport.height + 1
        }
    }
}

extension UINode {
    /// The process an iOS element belongs to; nil on Android and when the source did not say.
    public var iosPID: Int? {
        guard case .ios(let attributes) = native else { return nil }
        return attributes.pid
    }
}
