import Foundation

/// Why a sign-in screen could not be read. `ambiguous` is exit 6. `missing` and `noForm` are exit 2.
public struct LoginFormError: Equatable, Error, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        case missing
        case ambiguous
        /// No sign-in form is in front: nothing is an email or username field, and none was pinned.
        case noForm
    }

    public var kind: Kind
    public var message: String
    /// What holds the control's point, when a control was there and could not be reached.
    public var coveredBy: CoverReport?

    public init(kind: Kind, message: String, coveredBy: CoverReport? = nil) {
        self.kind = kind
        self.message = message
        self.coveredBy = coveredBy
    }

    public var description: String { message }
}

/// The email or username field, the password field and the submit button on the screen in front.
public enum LoginForm {
    public struct Found: Equatable, Sendable {
        public var identity: UINode
        public var password: UINode
        public var submit: UINode
        /// The iOS Turnstile web view, or the checkbox frame, when the tree shows exactly one.
        public var turnstileShell: UIFrame?
        /// Why the password field looks like web content rather than the app's own control; nil when nothing says so.
        public var webContainer: WebContainer?

        public init(identity: UINode, password: UINode, submit: UINode, turnstileShell: UIFrame?, webContainer: WebContainer? = nil) {
            self.identity = identity
            self.password = password
            self.submit = submit
            self.turnstileShell = turnstileShell
            self.webContainer = webContainer
        }
    }

    /// What marks a password field as web content.
    public enum WebContainer: Equatable, Sendable {
        /// An Android `WebView`, GeckoView or Crosswalk ancestor, an iOS runner `WebView`, or a simulator web area.
        case webView
        /// The field belongs to another Android package, or is missing one.
        case otherPackage(String?)
        /// The field belongs to another iOS process, as WebKit's web content does.
        case otherProcess
    }

    /// The app in front and how to map an iOS process to its bundle id, for the web-view checks that need them.
    public struct Origin {
        public var foreground: String
        public var bundleForPID: (Int) -> String?

        public init(foreground: String, bundleForPID: @escaping (Int) -> String? = { _ in nil }) {
            self.foreground = foreground
            self.bundleForPID = bundleForPID
        }
    }

    /// Pinned profile fields win. Anything omitted is detected. A covered control is refused.
    /// With `origin`, the package and process checks run as well as the structural web-view checks.
    /// `reachable` holds controls a hit-test at their own point found, which count as in front whatever the tree's order says.
    /// `answers` holds what each hit-test found, to name the cover in a refusal.
    public static func detect(in tree: UITree, profile: LoginProfile? = nil, origin: Origin? = nil, reachable: [UINode] = [], answers: [HitAnswer] = []) throws -> Found {
        let front = { (node: UINode) in isFrontmost(node, in: tree) || reachable.contains { isReached($0, node) } }
        let cover = { (node: UINode) in
            let hit = answers.first { sameIdentity($0.node, node) && $0.node.role == node.role }?.hit
            return (report: coverReport(of: node, in: tree, hit: hit), note: coverNote(of: node, in: tree, hit: hit))
        }
        let identity = try resolve(
            profile?.identity,
            roles: [.textField, .searchField],
            allowDisabled: false,
            named: isIdentityName,
            in: tree,
            front: front,
            cover: cover,
            what: "email or username field",
            missing: "No email or username field is in front.",
            noneKind: .noForm
        )
        let password = try resolve(
            profile?.password,
            roles: [.secureTextField],
            allowDisabled: false,
            named: { _ in true },
            in: tree,
            front: front,
            cover: cover,
            what: "password field",
            missing: "No password field is in front."
        )
        let submit = try resolve(
            profile?.submit,
            roles: [.button],
            allowDisabled: true,
            named: isSubmitName,
            below: password.frame,
            in: tree,
            front: front,
            cover: cover,
            what: "submit button",
            missing: "No Log in, Sign in, Continue or Next button is in front below the password field."
        )
        return Found(
            identity: identity, password: password, submit: submit, turnstileShell: shell(in: tree),
            webContainer: webContainer(of: password, in: tree, origin: origin)
        )
    }

    /// Android: a `WebView`, GeckoView or Crosswalk ancestor, or a package other than the app in front (fail closed). iOS: a `WebView` or web-area
    /// ancestor (fail closed), or a process other than the app's that maps to another bundle. No signal means native.
    public static func webContainer(of field: UINode, in tree: UITree, origin: Origin?) -> WebContainer? {
        guard let chain = ancestry(of: field, in: tree) else { return nil }
        switch tree.platform {
        case .android:
            if chain.contains(where: isAndroidWebView) { return .webView }
            if let origin {
                let package = androidPackage(of: field)
                if package != origin.foreground { return .otherPackage(package) }
            }
        case .ios:
            if chain.contains(where: isIOSWebView) { return .webView }
            if let origin, let pid = chain.reversed().lazy.compactMap(iosPID).first {
                let appPID = (tree.roots.flatMap { $0.flattened() }.first { $0.role == .application } ?? tree.roots.first).flatMap(iosPID)
                if pid != appPID, origin.bundleForPID(pid) != origin.foreground { return .otherProcess }
            }
        }
        return nil
    }

    /// The nodes from a root down to `field`, or nil when it is not in the tree.
    private static func ancestry(of field: UINode, in tree: UITree) -> [UINode]? {
        func walk(_ node: UINode, _ path: [UINode]) -> [UINode]? {
            let here = path + [node]
            if node == field { return here }
            for child in node.children {
                if let found = walk(child, here) { return found }
            }
            return nil
        }
        for root in tree.roots {
            if let found = walk(root, []) { return found }
        }
        return nil
    }

    private static func isAndroidWebView(_ node: UINode) -> Bool {
        guard case .android(let native) = node.native, let name = native.className else { return false }
        if name == "WebView" || name.hasSuffix(".WebView") { return true }
        return ["Gecko", "Crosswalk", "XWalk"].contains { name.contains($0) }
    }

    private static func isIOSWebView(_ node: UINode) -> Bool {
        guard case .ios(let native) = node.native else { return false }
        if native.type == "WebView" || native.role == "AXWebArea" { return true }
        return native.roleDescription?.lowercased() == "web area"
    }

    private static func androidPackage(of node: UINode) -> String? {
        guard case .android(let native) = node.native, let package = native.package?.trimmingCharacters(in: .whitespaces), !package.isEmpty else { return nil }
        return package
    }

    private static func iosPID(_ node: UINode) -> Int? {
        guard case .ios(let native) = node.native else { return nil }
        return native.pid
    }

    /// What a hit-test found at a control's own point; nil where nothing answered.
    public struct HitAnswer: Equatable, Sendable {
        public var node: UINode
        public var hit: UINode?

        public init(node: UINode, hit: UINode?) {
            self.node = node
            self.hit = hit
        }
    }

    /// Sign-in controls whose point only a container holds, for a hit-test as a normal step: nearest the front first, at most `perKind` of each kind.
    public static func unsettled(in tree: UITree, profile: LoginProfile? = nil, perKind: Int = 2) -> [UINode] {
        candidates(in: tree, profile: profile, perKind: perKind) { reading in
            if case .unsettled = reading { return true }
            return false
        }
    }

    /// Sign-in controls the tree places behind another node, such as a web widget's content listed last over the form, for a hit-test each once the form cannot be read without one.
    public static func hiddenCandidates(in tree: UITree, profile: LoginProfile? = nil, perKind: Int = 2) -> [UINode] {
        candidates(in: tree, profile: profile, perKind: perKind) { $0 != .front }
    }

    private enum ControlKind {
        case identity
        case password
        case submit
    }

    private static func candidates(in tree: UITree, profile: LoginProfile?, perKind: Int, where keeps: (SignInHit.Reading) -> Bool) -> [UINode] {
        let viewport = tree.viewport
        var taken: [ControlKind: Int] = [:]
        var found: [UINode] = []
        // The form is listed after any screen beneath it, so a screen of look-alikes cannot use up the reads.
        for node in visibleControls(in: tree).reversed() {
            guard let kind = kind(of: node, profile: profile), taken[kind, default: 0] < perKind,
                  let frame = node.frame, frame.width > 0, frame.height > 0, viewport.map(frame.isVisible(in:)) != false,
                  node.id?.isEmpty == false || node.label?.isEmpty == false,
                  !isFrontmost(node, in: tree), keeps(SignInHit.reading(of: node, in: tree, at: frame.center)) else { continue }
            taken[kind, default: 0] += 1
            found.append(node)
        }
        return found
    }

    private static func kind(of node: UINode, profile: LoginProfile?) -> ControlKind? {
        func pins(_ field: LoginField?) -> Bool {
            guard let field, field.id != nil || field.label != nil else { return false }
            return (field.id == nil || node.id == field.id) && (field.label == nil || node.label == field.label)
        }
        if pins(profile?.identity) { return .identity }
        if pins(profile?.password) { return .password }
        if pins(profile?.submit) { return .submit }
        switch node.role {
        case .textField, .searchField: return isIdentityName(node) ? .identity : nil
        case .secureTextField: return .password
        case .button: return isSubmitName(node) ? .submit : nil
        default: return nil
        }
    }

    /// A hit-test's answer is `node`, something it holds such as a button's own label, or text or an image drawn inside it that repeats part of its label.
    public static func isHit(_ hit: UINode, on node: UINode) -> Bool {
        guard let frame = node.frame, let hitFrame = hit.frame, frame.encloses(hitFrame, tolerance: 1) else { return false }
        if node.flattened().contains(where: { $0.role == hit.role && sameIdentity($0, hit) }) { return true }
        return isOwnLabel(hit, of: node)
    }

    /// A control's text comes back from a point read as a child the tree folds into it. Never a control, nor another process's view.
    private static func isOwnLabel(_ hit: UINode, of node: UINode) -> Bool {
        guard !hit.role.isActionable, hit.normalizedID == nil, let label = folded(hit.label), let mine = folded(node.label), mine.contains(label) else { return false }
        if let pid = iosPID(hit), let own = iosPID(node), pid != own { return false }
        return true
    }

    private static func folded(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// What holds `node`'s point: the hit-test's answer, else what the tree shows there. Nil when the tree shows nothing.
    public static func coverReport(of node: UINode, in tree: UITree, hit: UINode?) -> CoverReport? {
        let shown = treeCover(of: node, in: tree)
        guard let cover = hit ?? shown else { return nil }
        return CoverReport(CoverVerdict(cover: cover, evidence: hit == nil ? .treeOrder : .hitTest, isConfident: hit != nil))
    }

    /// One sentence: what the tree shows over `node`, and what a hit-test found there.
    public static func coverNote(of node: UINode, in tree: UITree, hit: UINode?) -> String? {
        var parts: [String] = []
        if let shown = treeCover(of: node, in: tree) {
            let holding = SignInHit.held(by: shown).map { " holding \(described($0))" } ?? ""
            parts.append("Over it: \(described(shown))\(holding)")
        }
        if let hit { parts.append("a hit-test there found \(described(hit))") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + "."
    }

    private static func treeCover(of node: UINode, in tree: UITree) -> UINode? {
        guard let frame = node.frame else { return nil }
        switch SignInHit.reading(of: node, in: tree, at: frame.center) {
        case .front: return nil
        case .covered(let top): return top
        case .unsettled(let top): return top
        }
    }

    /// `group (0, 0) 402x874` or `text "Cancel" (180, 744) 42x18`, with a label shown as the output masks allow.
    private static func described(_ node: UINode) -> String {
        var parts = [node.role.rawValue]
        if let label = node.normalizedLabel {
            parts.append(TerminalText.quoted(SelectorText.truncated(OutputMasks.current.mask.shownLabel(label, id: node.normalizedID))))
        } else if let id = node.normalizedID {
            parts.append(TerminalText.quoted(SelectorText.truncated(id)))
        }
        if let frame = node.frame { parts.append(frame.summary) }
        return parts.joined(separator: " ")
    }

    /// The email and password fields are on screen, by the tree or by the hit-tests in `reachable`. The submit button may still be under the keyboard.
    public static func credentialsAreVisible(in tree: UITree, profile: LoginProfile? = nil, reachable: [UINode] = []) -> Bool {
        let front = { (node: UINode) in isFrontmost(node, in: tree) || reachable.contains { isReached($0, node) } }
        do {
            _ = try resolve(
                profile?.identity,
                roles: [.textField, .searchField],
                allowDisabled: false,
                named: isIdentityName,
                in: tree,
                front: front,
                what: "email or username field",
                missing: "No email or username field is in front."
            )
            _ = try resolve(
                profile?.password,
                roles: [.secureTextField],
                allowDisabled: false,
                named: { _ in true },
                in: tree,
                front: front,
                what: "password field",
                missing: "No password field is in front."
            )
            return true
        } catch {
            return false
        }
    }

    /// The same control later in the flow, matched by id when it has one, else by label; of several, the one nearest where it was.
    public static func match(_ sample: UINode, in tree: UITree) -> UINode? {
        let found = visibleControls(in: tree).filter { $0.role == sample.role && sameIdentity($0, sample) }
        guard found.count > 1, let centre = sample.frame?.center else { return found.first }
        func distance(_ node: UINode) -> Double {
            guard let other = node.frame?.center else { return .infinity }
            return abs(other.x - centre.x) + abs(other.y - centre.y)
        }
        return found.min { distance($0) < distance($1) }
    }

    /// True when a point read at the centre lands on `node` or on something inside it. Android's drawing order settles an empty container's point, as no hit-test runs there.
    public static func isFrontmost(_ node: UINode, in tree: UITree) -> Bool {
        guard let frame = node.frame, frame.width > 0, frame.height > 0 else { return false }
        if let viewport = tree.viewport, !frame.isVisible(in: viewport) { return false }
        switch SignInHit.reading(of: node, in: tree, at: frame.center) {
        case .front: return true
        case .covered: return false
        case .unsettled: return node.isAndroidNode && CoverJudge.drawnClear(of: node, at: frame.center, in: tree)
        }
    }

    private static func resolve(
        _ pinned: LoginField?,
        roles: Set<UIRole>,
        allowDisabled: Bool,
        named: (UINode) -> Bool,
        below limit: UIFrame? = nil,
        in tree: UITree,
        front: (UINode) -> Bool,
        cover: (UINode) -> (report: CoverReport?, note: String?) = { _ in (nil, nil) },
        what: String,
        missing: String,
        noneKind: LoginFormError.Kind = .missing
    ) throws -> UINode {
        if let pinned {
            return try pinnedField(pinned, roles: roles, allowDisabled: allowDisabled, in: tree, front: front, cover: cover, what: what)
        }
        let named = visibleControls(in: tree).filter { node in
            guard roles.contains(node.role), named(node) else { return false }
            if !allowDisabled, node.enabled == false { return false }
            if let limit, let frame = node.frame, frame.center.y <= limit.y + limit.height { return false }
            return true
        }
        let matches = named.filter(front)
        guard let only = matches.first, matches.count == 1 else {
            if matches.isEmpty {
                let blocked = named.last.map(cover)
                let note = blocked?.note.map { " \($0)" } ?? ""
                throw LoginFormError(kind: noneKind, message: "\(missing) Nothing was typed.\(note)", coveredBy: blocked?.report)
            }
            let listed = matches.map(name).joined(separator: ", ")
            throw LoginFormError(kind: .ambiguous, message: "\(matches.count) \(what)s are in front (\(listed)). Nothing was typed.")
        }
        return only
    }

    private static func pinnedField(
        _ field: LoginField, roles: Set<UIRole>, allowDisabled: Bool, in tree: UITree, front: (UINode) -> Bool,
        cover: (UINode) -> (report: CoverReport?, note: String?), what: String
    ) throws -> UINode {
        let matches = visibleControls(in: tree).filter { node in
            if let id = field.id, node.id != id { return false }
            if let label = field.label, node.label != label { return false }
            return field.id != nil || field.label != nil
        }
        guard !matches.isEmpty else {
            throw LoginFormError(kind: .missing, message: "No \(what) matches \(field.described). Nothing was typed.")
        }
        if matches.allSatisfy({ !roles.contains($0.role) }) {
            throw LoginFormError(kind: .missing, message: "\(field.described) is a \(matches[0].role.rawValue), not a \(what). Nothing was typed.")
        }
        let front = matches.filter { node in
            roles.contains(node.role) && (allowDisabled || node.enabled != false) && front(node)
        }
        guard let only = front.first, front.count == 1 else {
            if front.isEmpty {
                let blocked = matches.last { roles.contains($0.role) }.map(cover)
                let note = blocked?.note.map { " \($0)" } ?? ""
                throw LoginFormError(kind: .missing, message: "\(field.described) is covered by another control. Nothing was typed.\(note)", coveredBy: blocked?.report)
            }
            throw LoginFormError(kind: .ambiguous, message: "\(front.count) controls match \(field.described). Nothing was typed.")
        }
        return only
    }

    private static func shell(in tree: UITree) -> UIFrame? {
        let shells = TurnstileWidget.iosShells(in: tree.roots, viewport: tree.viewport)
        if shells.count == 1 { return shells[0] }
        if case .ready(let target) = TurnstileWidget.phase(in: tree.roots, viewport: tree.viewport) {
            return target.frame
        }
        return nil
    }

    /// Controls outside the software keyboard and React Native's LogBox, so a Next key or a logged `[SIGNIN] widget expired` is not the submit button.
    static func visibleControls(in tree: UITree) -> [UINode] {
        var output: [UINode] = []
        let viewport = tree.viewport
        func walk(_ node: UINode, insideKeyboard: Bool) {
            if node.role == .keyboard || insideKeyboard {
                for child in node.children { walk(child, insideKeyboard: true) }
                return
            }
            if let viewport, KnownOverlays.logBoxToast(node, viewport: viewport) != nil { return }
            output.append(node)
            for child in node.children { walk(child, insideKeyboard: false) }
        }
        for root in tree.roots { walk(root, insideKeyboard: false) }
        return output
    }

    private static func isIdentityName(_ node: UINode) -> Bool {
        let flat = tokens(node).joined()
        return flat.contains("email") || flat.contains("username")
    }

    /// Whole words or two adjacent ones, so Log in matches and Blog index does not. "with" marks a social sign-in button.
    private static func isSubmitName(_ node: UINode) -> Bool {
        let words = tokens(node)
        if words.contains(where: { ["forgot", "create", "back", "support", "with"].contains($0) }) { return false }
        let candidates = Set(words + zip(words, words.dropFirst()).map { $0 + $1 })
        return !candidates.isDisjoint(with: ["login", "signin", "submit", "continue", "next"])
    }

    private static func tokens(_ node: UINode) -> [String] {
        let raw = [node.label, node.id].compactMap { $0 }.map(splitCamelCase).joined(separator: " ").lowercased()
        return raw.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// `signInButton` and `OSLogin` become `sign In Button` and `OS Login`.
    private static func splitCamelCase(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        for (index, character) in characters.enumerated() {
            if index > 0, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    output.append(" ")
                }
            }
            output.append(character)
        }
        return output
    }

    /// A control a hit-test reached, read again: the same role and name in the same place, so a twin on a screen beneath does not count.
    private static func isReached(_ reached: UINode, _ node: UINode) -> Bool {
        guard reached.role == node.role, sameIdentity(reached, node), let theirs = reached.frame, let mine = node.frame else { return false }
        return theirs.isWithinTolerance(of: mine)
    }

    private static func sameIdentity(_ node: UINode, _ sample: UINode) -> Bool {
        if let id = sample.id, !id.isEmpty { return node.id == id }
        return node.label == sample.label
    }

    private static func name(_ node: UINode) -> String {
        if let id = node.id, !id.isEmpty { return "id=\(id)" }
        if let label = node.label, !label.isEmpty { return "label=\(label)" }
        return node.role.rawValue
    }
}
