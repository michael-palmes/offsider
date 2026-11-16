import Foundation

/// What an input would do to the screen, as far as a guard cares.
public enum GuardInput: Equatable, Sendable {
    /// A tap, a long press, a touch going down or a slider being set, at a point.
    case press(UIPoint)
    /// A swipe or a drag.
    case path(from: UIPoint, to: UIPoint)
    /// Return, Enter, Space or a select key, which presses whatever the screen treats as its default.
    case activate
}

/// The guarded control an input would land on.
public struct GuardHit: Equatable, Sendable {
    public var action: GuardAction
    public var rule: GuardRule
    /// The control's label, else its id; nil when the tree shows nothing under the point.
    public var control: String?
    /// The control's id, so its label can be shown as the output mask shows it.
    public var controlID: String?
    /// True when the tree could not say what is under the point on a guarded screen, so a person decides.
    public var unsure: Bool

    public init(action: GuardAction, rule: GuardRule, control: String? = nil, controlID: String? = nil, unsure: Bool = false) {
        self.action = action
        self.rule = rule
        self.control = control
        self.controlID = controlID
        self.unsure = unsure
    }

    init(_ rule: GuardRule, on node: UINode?) {
        self.init(action: rule.action, rule: rule, control: node?.normalizedLabel ?? node?.normalizedID, controlID: node?.normalizedID)
    }
}

/// Decides whether an input lands on a guarded control. Pure: the tree and the rules in, a verdict out.
public enum GuardJudge {
    /// Labels a look-only screen always lets through, so an agent can leave it.
    static let leaveLabels: Set<String> = ["back", "close", "cancel", "dismiss", "navigate up", "not now"]

    /// The strictest rule the input would trip, or nil when it is free; `textNear` reads the words around a point the tree shows nothing at.
    public static func verdict(rules: [GuardRule], tree: UITree, input: GuardInput, textNear: ((UIPoint) -> [String]?)? = nil) -> GuardHit? {
        guard !rules.isEmpty else { return nil }
        let shown = shownNodes(in: tree)
        let active = rules.filter { rule in rule.screen.map { marker in shown.contains(where: marker.matches) } ?? true }
        guard !active.isEmpty else { return nil }
        switch input {
        case .press(let point):
            return press(at: point, active: active, shown: shown, viewport: tree.viewport, textNear: textNear, horizontal: nil)
        case .path(let from, let to):
            return press(at: from, active: active, shown: shown, viewport: tree.viewport, textNear: textNear, horizontal: abs(to.x - from.x) > abs(to.y - from.y))
        case .activate:
            let hits = active.compactMap { rule -> GuardHit? in
                guard let control = rule.control else { return GuardHit(action: rule.action, rule: rule) }
                return shown.first(where: control.matches).map { GuardHit(rule, on: $0) }
            }
            return strictest(hits)
        }
    }

    /// The share of the screen above which an element is a container, which says nothing about one point inside it.
    static let containerShare = 0.25

    /// A control counts when its frame holds the point, wherever it sits in the tree, as a tree's order is not the screen's; `horizontal` is nil for a press.
    private static func press(at point: UIPoint, active: [GuardRule], shown: [UINode], viewport: UIFrame?, textNear: ((UIPoint) -> [String]?)?, horizontal: Bool?) -> GuardHit? {
        func area(_ node: UINode) -> Double { node.frame.map { $0.width * $0.height } ?? .infinity }
        // An app or a window is under every point of a screen, so its own name never makes a control of it.
        let under = shown.filter { $0.frame?.contains(point) == true && $0.role != .application && $0.role != .window }.sorted { area($0) < area($1) }
        let limit = viewport.map { $0.width * $0.height * containerShare } ?? .infinity
        // A container says nothing about one point inside it, so only smaller elements name what is there.
        let near = under.filter { area($0) <= limit }
        let named = near.first { $0.normalizedLabel != nil || $0.normalizedID != nil }
        var hits: [GuardHit] = []
        for rule in active {
            if let control = rule.control {
                if let node = under.first(where: control.matches) { hits.append(GuardHit(rule, on: node)) }
            } else if horizontal == nil, !near.contains(where: { node in isLeave(node) || rule.except.contains { $0.matches(node) } }) {
                hits.append(GuardHit(rule, on: named))
            }
        }
        if let hit = strictest(hits) { return hit }
        let scoped = active.filter { $0.screen != nil && $0.control != nil }
        guard named == nil, horizontal != false, let first = scoped.max(by: { $0.action < $1.action }) else { return nil }
        guard let texts = textNear?(point) else { return GuardHit(action: .ask, rule: first, unsure: true) }
        let read = scoped.compactMap { rule -> GuardHit? in
            guard let control = rule.control, let text = texts.first(where: control.matches(text:)) else { return nil }
            return GuardHit(action: rule.action, rule: rule, control: text)
        }
        if let hit = strictest(read) { return hit }
        // Words that match no label still leave a rule that names only an id unanswered.
        if !texts.isEmpty, scoped.contains(where: { $0.control?.hasLabel == false }) { return GuardHit(action: .ask, rule: first, control: texts.first, unsure: true) }
        return nil
    }

    private static func strictest(_ hits: [GuardHit]) -> GuardHit? {
        hits.first { $0.action == .never } ?? hits.first
    }

    private static func isLeave(_ node: UINode) -> Bool {
        node.normalizedLabel.map { leaveLabels.contains(GuardMatcher.folded($0)) } ?? false
    }

    /// Every node with a frame inside the screen; a tree with no screen counts them all.
    static func shownNodes(in tree: UITree) -> [UINode] {
        let viewport = tree.viewport
        return tree.roots.flatMap { $0.flattened() }.filter { node in
            guard let frame = node.frame else { return false }
            return viewport.map(frame.isVisible(in:)) ?? true
        }
    }

    /// Whether any rule's control or screen marker shows in the tree: `guard check` uses it to prove a rule on a device.
    public static func seen(_ rule: GuardRule, in tree: UITree) -> (screen: Bool, control: Bool) {
        let shown = shownNodes(in: tree)
        let screen = rule.screen.map { marker in shown.contains(where: marker.matches) } ?? true
        let control = rule.control.map { matcher in shown.contains(where: matcher.matches) } ?? screen
        return (screen, control)
    }
}

extension GuardInput {
    /// The HID usages of Return and the keypad's Enter, which press a form's default control.
    static let activatingKeys: Set<UInt32> = [40, 88]
    /// A finger that lifts within this many points of where it went down pressed one spot.
    static let pressSlop = 10.0

    /// What an event would do, in the event's own coordinates: where a finger goes down and how far it travels, and whether Return is pressed.
    public static func inputs(of event: InputEvent) -> [GuardInput] {
        var found: [GuardInput] = []
        var down: UIPoint?
        var last: UIPoint?
        var twoDown = false
        var activates = false
        func lift() {
            guard let start = down else { return }
            let end = last ?? start
            found.append(abs(end.x - start.x) > pressSlop || abs(end.y - start.y) > pressSlop ? .path(from: start, to: end) : .press(start))
            down = nil
            last = nil
        }
        func walk(_ event: InputEvent) {
            switch event {
            case let .tapAt(x, y):
                found.append(.press(UIPoint(x: x, y: y)))
            case let .touch(.down, x, y):
                if down == nil { down = UIPoint(x: x, y: y) }
                last = UIPoint(x: x, y: y)
            case let .touch(.up, x, y):
                if down != nil { last = UIPoint(x: x, y: y) }
                lift()
            case let .twoFingerTouch(.down, x1, y1, x2, y2):
                if !twoDown { found += [.press(UIPoint(x: x1, y: y1)), .press(UIPoint(x: x2, y: y2))] }
                twoDown = true
            case .twoFingerTouch(.up, _, _, _, _):
                twoDown = false
            case let .swipe(xStart, yStart, xEnd, yEnd, _, _):
                found.append(.path(from: UIPoint(x: xStart, y: yStart), to: UIPoint(x: xEnd, y: yEnd)))
            case .keyboard(.down, let code), .shortKeyPress(let code):
                if activatingKeys.contains(code) { activates = true }
            case .composite(let events):
                events.forEach(walk)
            case .keyboard(.up, _), .button, .shortButtonPress, .delay:
                break
            }
        }
        walk(event)
        lift()
        return found + (activates ? [.activate] : [])
    }

    /// The same input with each point moved by `map`, from an event's coordinates to the tree's.
    public func mapped(_ map: (UIPoint) -> UIPoint) -> GuardInput {
        switch self {
        case .press(let point): return .press(map(point))
        case .path(let from, let to): return .path(from: map(from), to: map(to))
        case .activate: return .activate
        }
    }
}

/// Undoes a backend's turn, scale and offset of screen points, found from three points it mapped.
public struct GuardPointMap: Equatable, Sendable {
    /// Screen points to map forward, well inside any screen.
    public static let probes = [UIPoint(x: 10, y: 10), UIPoint(x: 110, y: 10), UIPoint(x: 10, y: 110)]

    let origin: UIPoint
    let alongX: UIPoint
    let alongY: UIPoint
    let determinant: Double

    /// `mapped` are `probes` in input coordinates; nil when they do not span a plane.
    public init?(mapped: [UIPoint]) {
        guard mapped.count == 3 else { return nil }
        origin = mapped[0]
        alongX = UIPoint(x: (mapped[1].x - mapped[0].x) / 100, y: (mapped[1].y - mapped[0].y) / 100)
        alongY = UIPoint(x: (mapped[2].x - mapped[0].x) / 100, y: (mapped[2].y - mapped[0].y) / 100)
        determinant = alongX.x * alongY.y - alongY.x * alongX.y
        guard determinant.isFinite, abs(determinant) > 1e-9 else { return nil }
    }

    /// The screen point an input point came from.
    public func screenPoint(_ input: UIPoint) -> UIPoint {
        let dx = input.x - origin.x
        let dy = input.y - origin.y
        return UIPoint(x: 10 + (dx * alongY.y - alongY.x * dy) / determinant, y: 10 + (alongX.x * dy - dx * alongX.y) / determinant)
    }
}
