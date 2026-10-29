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

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
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
    public static func detect(in tree: UITree, profile: LoginProfile? = nil, origin: Origin? = nil, reachable: [UINode] = []) throws -> Found {
        let front = { (node: UINode) in isFrontmost(node, in: tree) || reachable.contains { sameIdentity($0, node) && $0.role == node.role } }
        let identity = try resolve(
            profile?.identity,
            roles: [.textField, .searchField],
            allowDisabled: false,
            named: isIdentityName,
            in: tree,
            front: front,
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

    /// On-screen sign-in candidates the tree places behind another node, for a hit-test at each one's own point: a view drawn by another
    /// process inside the form, such as a web widget, can sit last in the tree with a frame that reaches over the fields.
    public static func hiddenCandidates(in tree: UITree, profile: LoginProfile? = nil, limit: Int = 6) -> [UINode] {
        let pinned = [profile?.identity, profile?.password, profile?.submit].compactMap { $0 }
        let viewport = tree.viewport
        let found = visibleControls(in: tree).filter { node in
            guard let frame = node.frame, frame.width > 0, frame.height > 0, viewport.map(frame.isVisible(in:)) != false else { return false }
            guard node.id?.isEmpty == false || node.label?.isEmpty == false, !isFrontmost(node, in: tree) else { return false }
            if pinned.contains(where: { field in (field.id == nil || node.id == field.id) && (field.label == nil || node.label == field.label) }) { return true }
            switch node.role {
            case .textField, .searchField: return isIdentityName(node)
            case .secureTextField: return true
            case .button: return isSubmitName(node)
            default: return false
            }
        }
        return Array(found.prefix(limit))
    }

    /// A hit-test's answer is `node`, or something it holds such as a button's own label.
    public static func isHit(_ hit: UINode, on node: UINode) -> Bool {
        guard let frame = node.frame, let hitFrame = hit.frame, frame.encloses(hitFrame, tolerance: 1) else { return false }
        return node.flattened().contains { $0.role == hit.role && sameIdentity($0, hit) }
    }

    /// The email and password fields are on screen. The submit button may still be under the keyboard.
    public static func credentialsAreVisible(in tree: UITree, profile: LoginProfile? = nil) -> Bool {
        do {
            _ = try resolve(
                profile?.identity,
                roles: [.textField, .searchField],
                allowDisabled: false,
                named: isIdentityName,
                in: tree,
                what: "email or username field",
                missing: "No email or username field is in front."
            )
            _ = try resolve(
                profile?.password,
                roles: [.secureTextField],
                allowDisabled: false,
                named: { _ in true },
                in: tree,
                what: "password field",
                missing: "No password field is in front."
            )
            return true
        } catch {
            return false
        }
    }

    /// The same control later in the flow, matched by id when it has one, else by label.
    public static func match(_ sample: UINode, in tree: UITree) -> UINode? {
        visibleControls(in: tree).first { node in
            node.role == sample.role && sameIdentity(node, sample)
        }
    }

    /// True when a point read at the centre lands on `node` or on something inside it.
    public static func isFrontmost(_ node: UINode, in tree: UITree) -> Bool {
        guard let frame = node.frame, frame.width > 0, frame.height > 0 else { return false }
        if let viewport = tree.viewport, !frame.isVisible(in: viewport) { return false }
        return SignInHit.chain(in: tree, at: frame.center).contains { $0.isSameElement(as: node) }
    }

    private static func resolve(
        _ pinned: LoginField?,
        roles: Set<UIRole>,
        allowDisabled: Bool,
        named: (UINode) -> Bool,
        below limit: UIFrame? = nil,
        in tree: UITree,
        front: ((UINode) -> Bool)? = nil,
        what: String,
        missing: String,
        noneKind: LoginFormError.Kind = .missing
    ) throws -> UINode {
        let front = front ?? { isFrontmost($0, in: tree) }
        if let pinned {
            return try pinnedField(pinned, roles: roles, allowDisabled: allowDisabled, in: tree, front: front, what: what)
        }
        let matches = visibleControls(in: tree).filter { node in
            guard roles.contains(node.role), named(node) else { return false }
            if !allowDisabled, node.enabled == false { return false }
            if let limit, let frame = node.frame, frame.center.y <= limit.y + limit.height { return false }
            return front(node)
        }
        guard let only = matches.first, matches.count == 1 else {
            if matches.isEmpty {
                throw LoginFormError(kind: noneKind, message: "\(missing) Nothing was typed.")
            }
            let listed = matches.map(name).joined(separator: ", ")
            throw LoginFormError(kind: .ambiguous, message: "\(matches.count) \(what)s are in front (\(listed)). Nothing was typed.")
        }
        return only
    }

    private static func pinnedField(_ field: LoginField, roles: Set<UIRole>, allowDisabled: Bool, in tree: UITree, front: (UINode) -> Bool, what: String) throws -> UINode {
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
                throw LoginFormError(kind: .missing, message: "\(field.described) is covered by another control. Nothing was typed.")
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

    /// Controls outside the software keyboard, so a Next key is not the submit button.
    static func visibleControls(in tree: UITree) -> [UINode] {
        var output: [UINode] = []
        func walk(_ node: UINode, insideKeyboard: Bool) {
            if node.role == .keyboard || insideKeyboard {
                for child in node.children { walk(child, insideKeyboard: true) }
                return
            }
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
