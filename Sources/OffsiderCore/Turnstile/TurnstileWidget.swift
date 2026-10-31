import Foundation

/// The checkbox a person would tick. Offsider reports where it is and never taps it.
public struct TurnstileTarget: Equatable, Sendable {
    public var frame: UIFrame

    public init(frame: UIFrame) {
        self.frame = frame
    }
}

/// What a screen's accessibility tree says about a Cloudflare Turnstile widget.
public enum TurnstilePhase: Equatable, Sendable {
    case absent
    case checking
    case ready(TurnstileTarget)
    /// The widget reads Success.
    case passed
    /// An image grid for a person to solve.
    case visualChallenge
    /// More than one checkbox is on screen.
    case ambiguous(Int)
    /// An element named for Turnstile is on screen with no widget in it: the widget failed to run, or runs invisibly, which a tree cannot tell apart.
    case noWidget
}

/// Finds a Turnstile widget in an accessibility tree and reads its state.
public enum TurnstileWidget {
    /// Cloudflare's own container. The suffix changes on every load.
    public static let widgetIDPrefix = "cf-chl-widget"
    /// A Cloudflare container this tall, with no checkbox or Success label, is an expanded challenge rather than the compact widget.
    public static let visualChallengeHeight = 160.0
    /// The iOS checkbox square, from a 3x capture of the green check (30pt across).
    public static let iosSquareSide = 30.0
    /// Points from the iOS web view's left edge to that square's centre.
    public static let iosSquareCentreInset = 32.0

    /// `scopeID` limits the search to that element and its descendants, such as an app's wrapper around the widget.
    public static func phase(in roots: [UINode], viewport: UIFrame? = nil, scopeID: String? = nil) -> TurnstilePhase {
        let roots = scoped(roots, id: scopeID)
        guard !roots.isEmpty else { return .absent }

        let widgets = containers(in: roots, viewport: viewport)
        if widgets.isEmpty {
            let fallback = fallbackCheckbox(in: roots, viewport: viewport)
            return fallback == .absent && namesTurnstile(roots, viewport: viewport) ? .noWidget : fallback
        }

        let phases = widgets.map { assess($0, viewport: viewport) }
        let ready = phases.compactMap { phase -> TurnstileTarget? in
            if case .ready(let target) = phase { return target }
            return nil
        }
        if ready.count > 1 { return .ambiguous(ready.count) }
        if let target = ready.first { return .ready(target) }
        if phases.contains(.visualChallenge) { return .visualChallenge }
        if phases.contains(.passed) { return .passed }
        return .checking
    }

    /// A short, wide web view whose only words are scroll bars. iOS leaves the widget's contents out of the tree.
    public static func iosShells(in roots: [UINode], viewport: UIFrame? = nil, scopeID: String? = nil) -> [UIFrame] {
        let nodes = scoped(roots, id: scopeID).flatMap { $0.flattened() }.filter { onScreen($0, viewport: viewport) }
        var frames: [UIFrame] = []
        for node in nodes where isIOSShell(node) {
            guard let frame = node.frame, !frames.contains(where: { samePlace($0, frame) }) else { continue }
            frames.append(frame)
        }
        return frames
    }

    /// Where to read the widget once `iosShells` has found the web view: the status words, then the logo.
    public static func probePoints(in shell: UIFrame) -> (status: UIPoint, logo: UIPoint) {
        let y = shell.y + shell.height / 2
        return (
            UIPoint(x: shell.x + 80, y: y),
            UIPoint(x: shell.x + shell.width - 54, y: y)
        )
    }

    /// The checkbox square for an iOS web view. Its centre is the green check.
    public static func iosTarget(_ shell: UIFrame) -> TurnstileTarget {
        let side = iosSquareSide
        let x = shell.x + iosSquareCentreInset - side / 2
        let y = shell.y + shell.height / 2 - side / 2
        return TurnstileTarget(frame: UIFrame(x: x, y: y, width: side, height: side))
    }

    /// What a point inside the web view says. `passed` wins over a prompt, then a check in progress, then the logo.
    public static func reading(in roots: [UINode]) -> TurnstileReading {
        roots.flatMap { $0.flattened() }.reduce(.unrelated) { prefer($0, reading(of: $1)) }
    }

    /// Combines one reading of each shell. Two confirmed widgets are ambiguous.
    public static func phase(
        of samples: [(frame: UIFrame, status: TurnstileReading, logo: TurnstileReading)]
    ) -> TurnstilePhase {
        let found = samples.map { phase(shell: $0.frame, status: $0.status, logo: $0.logo) }.filter { !isAbsent($0) }
        if found.count > 1 { return .ambiguous(found.count) }
        return found.first ?? .absent
    }

    /// `logo` confirms the web view when the checkbox itself has no accessibility text.
    public static func phase(shell: UIFrame, status: TurnstileReading, logo: TurnstileReading) -> TurnstilePhase {
        let readings = [status, logo]
        if readings.contains(.passed) { return .passed }
        if readings.contains(.checking) { return .checking }
        if readings.contains(.prompt) || readings.contains(.logo) { return .ready(iosTarget(shell)) }
        return .absent
    }

    private static func scoped(_ roots: [UINode], id: String?) -> [UINode] {
        guard let id else { return roots }
        return roots.flatMap { $0.flattened() }.filter { $0.id == id }
    }

    /// Cloudflare's container when the tree has one, otherwise an app wrapper with that id.
    private static func containers(in roots: [UINode], viewport: UIFrame?) -> [UINode] {
        let nodes = roots.flatMap { $0.flattened() }.filter { onScreen($0, viewport: viewport) }
        let cloudflare = nodes.filter { $0.id?.hasPrefix(widgetIDPrefix) == true }
        if !cloudflare.isEmpty { return cloudflare }
        return nodes.filter { $0.id == "turnstile-widget" }
    }

    private static func assess(_ widget: UINode, viewport: UIFrame?) -> TurnstilePhase {
        let nodes = widget.flattened().filter { onScreen($0, viewport: viewport) }
        let checkbox = nodes.first { $0.role == .checkbox && $0.frame != nil }
        let success = nodes.contains { isSuccess($0) }
        let challenge = nodes.contains { isVisualChallenge($0) }
        let tall = widget.id?.hasPrefix(widgetIDPrefix) == true && (widget.frame?.height ?? 0) > visualChallengeHeight
        if challenge || (tall && checkbox == nil && !success) {
            return .visualChallenge
        }
        if success { return .passed }
        if let checkbox, let frame = checkbox.frame {
            return .ready(TurnstileTarget(frame: frame))
        }
        return .checking
    }

    /// An app's own web view or wrapper for the widget, on screen.
    private static func namesTurnstile(_ roots: [UINode], viewport: UIFrame?) -> Bool {
        roots.flatMap { $0.flattened() }.contains { node in
            node.id?.range(of: "turnstile", options: .caseInsensitive) != nil && onScreen(node, viewport: viewport)
        }
    }

    /// A checkbox labelled as Turnstile's prompt, for a tree that exposes the control without Cloudflare's container id.
    /// With no checkbox, the Cloudflare logo marks the widget, so its Success or checking words count.
    private static func fallbackCheckbox(in roots: [UINode], viewport: UIFrame?) -> TurnstilePhase {
        let nodes = roots.flatMap { $0.flattened() }.filter { onScreen($0, viewport: viewport) }
        let boxes = nodes.filter { $0.role == .checkbox && $0.frame != nil && isPrompt($0) }
        if boxes.count > 1 { return .ambiguous(boxes.count) }
        let logo = nodes.first { isLogo($0) }?.frame
        guard let box = boxes.first, let frame = box.frame else {
            guard logo != nil else { return .absent }
            if nodes.contains(where: { isSuccess($0) }) { return .passed }
            if nodes.contains(where: { isChecking($0) }) { return .checking }
            return .absent
        }
        return .ready(TurnstileTarget(frame: frame))
    }

    private static func onScreen(_ node: UINode, viewport: UIFrame?) -> Bool {
        guard let viewport else { return true }
        if let frame = node.frame, frame.isVisible(in: viewport) { return true }
        return node.children.contains { onScreen($0, viewport: viewport) }
    }

    private static func isIOSShell(_ node: UINode) -> Bool {
        guard node.role == .scrollView, let frame = node.frame else { return false }
        guard (60...110).contains(frame.height), frame.width >= 240, frame.width > frame.height * 3 else { return false }
        let descendants = node.flattened().dropFirst()
        guard descendants.contains(where: { $0.role == .slider }) else { return false }
        return descendants.allSatisfy { candidate in
            candidate.role == .slider || texts(of: candidate).allSatisfy(isTurnstileCopy)
        }
    }

    private static func isTurnstileCopy(_ text: String) -> Bool {
        let plain = plain(text)
        if plain.isEmpty { return true }
        return isSuccessText(plain) || isPromptText(plain) || isCheckingText(plain) || plain.contains("cloudflare")
    }

    private static func samePlace(_ lhs: UIFrame, _ rhs: UIFrame) -> Bool {
        abs(lhs.x - rhs.x) < 1 && abs(lhs.y - rhs.y) < 1 && abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    private static func isAbsent(_ phase: TurnstilePhase) -> Bool {
        if case .absent = phase { return true }
        return false
    }

    private static func reading(of node: UINode) -> TurnstileReading {
        if isSuccess(node) { return .passed }
        if node.role == .checkbox || isPrompt(node) { return .prompt }
        if isChecking(node) { return .checking }
        if isLogo(node) { return .logo }
        return .unrelated
    }

    private static func prefer(_ current: TurnstileReading, _ next: TurnstileReading) -> TurnstileReading {
        rank(next) > rank(current) ? next : current
    }

    private static func rank(_ reading: TurnstileReading) -> Int {
        switch reading {
        case .unrelated: 0
        case .logo: 1
        case .checking: 2
        case .prompt: 3
        case .passed: 4
        }
    }

    private static func isSuccess(_ node: UINode) -> Bool {
        texts(of: node).contains { isSuccessText(plain($0)) }
    }

    private static func isSuccessText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "!."))
        return trimmed == "success" || trimmed == "verified"
    }

    private static func isPrompt(_ node: UINode) -> Bool {
        texts(of: node).contains { isPromptText(plain($0)) }
    }

    private static func isPromptText(_ text: String) -> Bool {
        text.contains("verify you are human") || text.contains("confirm you are human") || text == "i am human"
    }

    private static func isChecking(_ node: UINode) -> Bool {
        texts(of: node).contains { isCheckingText(plain($0)) }
    }

    private static func isCheckingText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "!.…"))
        return trimmed == "verifying" || trimmed.hasPrefix("checking")
    }

    private static func isVisualChallenge(_ node: UINode) -> Bool {
        texts(of: node).contains { text in
            let plain = plain(text)
            return plain.contains("select all") || plain.contains("select every")
        }
    }

    private static func isLogo(_ node: UINode) -> Bool {
        guard node.frame != nil else { return false }
        let text = texts(of: node).map { plain($0) }.joined(separator: " ")
        return text.contains("cloudflare") && (node.role == .button || node.role == .link || text.contains("opens in a new tab"))
    }

    private static func texts(of node: UINode) -> [String] {
        [node.label, node.value].compactMap { $0 }
    }

    private static func plain(_ label: String?) -> String {
        guard let label else { return "" }
        return label.lowercased().split { $0.isWhitespace }.joined(separator: " ")
    }
}

/// A point read inside an iOS Turnstile web view.
public enum TurnstileReading: Equatable, Sendable {
    case passed
    case checking
    case prompt
    case logo
    case unrelated
}

/// What `turnstile` prints: the widget's state from one read. Offsider never taps it.
public struct TurnstileStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case checkbox
        case verifying
        case passed
        case challenge
        case absent
        /// A Turnstile web view with no widget: do not read it as absent.
        case unknown

        /// A person's step is still open: there is something to tick or solve, or a tick being checked.
        public var awaitsPerson: Bool {
            switch self {
            case .checkbox, .challenge, .verifying: return true
            case .passed, .absent, .unknown: return false
            }
        }
    }

    public enum Source: String, Sendable {
        case tree
        /// iOS: points read inside the web view, which leaves the checkbox out of the tree.
        case webViewPoints = "web-view-points"
    }

    public var state: State
    public var source: Source
    public var frame: UIFrame?

    public init(state: State, source: Source, frame: UIFrame? = nil) {
        self.state = state
        self.source = source
        self.frame = frame
    }

    /// Nil for `ambiguous`, which the caller reports as several checkboxes.
    public init?(phase: TurnstilePhase, source: Source) {
        switch phase {
        case .absent: self.init(state: .absent, source: source)
        case .checking: self.init(state: .verifying, source: source)
        case .ready(let target): self.init(state: .checkbox, source: source, frame: target.frame)
        case .passed: self.init(state: .passed, source: source)
        case .visualChallenge: self.init(state: .challenge, source: source)
        case .noWidget: self.init(state: .unknown, source: source)
        case .ambiguous: return nil
        }
    }

    /// What `unknown` means and where to look next.
    public static let unknownNote = "A Turnstile web view is up with no widget: it failed to run, or runs invisibly. Check the app's log for a Turnstile error, and doctor for an old WebView."

    /// `Turnstile: checkbox at (32, 388.95) 163.81x25.14`, or the state alone.
    public func textLine() -> String {
        guard let frame else { return "Turnstile: \(state.rawValue)" + (state == .unknown ? ". \(Self.unknownNote)" : "") }
        return "Turnstile: \(state.rawValue) at (\(Self.format(frame.x)), \(Self.format(frame.y))) \(Self.format(frame.width))x\(Self.format(frame.height))"
    }

    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("state", .string(state.rawValue)),
            ("source", .string(source.rawValue)),
            ("frame", frame.map { frame in
                .object([
                    ("x", .number(Self.rounded(frame.x))),
                    ("y", .number(Self.rounded(frame.y))),
                    ("width", .number(Self.rounded(frame.width))),
                    ("height", .number(Self.rounded(frame.height))),
                ])
            } ?? .null),
        ]).rendered(compact: true)
    }

    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func format(_ value: Double) -> String {
        let rounded = Self.rounded(value)
        return rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded)
    }
}
