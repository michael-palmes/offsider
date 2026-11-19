import Foundation

/// What `login --fill` types: the saved password into password fields, or the saved email or username into one text field.
public enum LoginFillTarget: String, CaseIterable, Sendable {
    case password
    case identity

    /// `password field` or `email or username field`, for a sentence.
    public var fieldName: String {
        switch self {
        case .password: "password field"
        case .identity: "email or username field"
        }
    }
}

/// Why `login --fill` typed nothing into a screen.
public struct LoginFillRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// No field matches, or none is in front.
        case missing
        case ambiguous
        /// More password fields are in front than one fill may type into.
        case tooMany
        /// A field anyone can read, where the password would show.
        case visible
        /// A field whose kind the screen does not say.
        case unreadable
        /// A show-password toggle is on, or a password field shows its text.
        case revealed
        /// The field already holds text and `--replace` was not passed.
        case holdsText
        /// The field has no id or label to type into.
        case unnamed
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

/// The fields `login --fill` may type into on the screen in front, and the rules each passes again before it is typed into.
public enum LoginFill {
    /// A password and its confirmation; a screen with more names its field with `--into-id`.
    public static let maximumFields = 2

    /// The fields to fill, top to bottom, or a refusal before anything is typed. `reachable` holds fields a hit-test at their own point found.
    public static func fields(
        _ target: LoginFillTarget, in tree: UITree, intoID: String?, replace: Bool, reachable: [UINode] = [], revealed: RevealedSecrets? = nil
    ) throws -> [UINode] {
        let front = { (node: UINode) in LoginForm.isFrontmost(node, in: tree) || reachable.contains { LoginForm.isReached($0, node) } }
        let controls = LoginForm.visibleControls(in: tree)
        if target == .password { try refuseRevealed(in: tree, revealed: revealed) }
        let chosen: [UINode]
        if let intoID {
            chosen = [try named(intoID, target: target, in: controls, front: front, revealed: revealed)]
        } else {
            chosen = try detected(target, in: controls, front: front)
        }
        for field in chosen { try check(field, target, in: tree, replace: replace, revealed: revealed) }
        return chosen.sorted { ($0.frame?.y ?? 0, $0.frame?.x ?? 0) < ($1.frame?.y ?? 0, $1.frame?.x ?? 0) }
    }

    /// Fields the tree cannot place in front by itself, for a hit-test each: at most `maximumFields + 1`, nearest the front first.
    public static func unsettled(_ target: LoginFillTarget, in tree: UITree, intoID: String?) -> [UINode] {
        let viewport = tree.viewport
        let found = LoginForm.visibleControls(in: tree).reversed().filter { node in
            guard let frame = node.frame, frame.width > 0, frame.height > 0, viewport.map(frame.isVisible(in:)) != false else { return false }
            if let intoID { return node.normalizedID == intoID }
            return target == .password ? node.isSecure : node.role.isTextInput && !node.isSecure && LoginForm.isIdentityName(node)
        }
        return Array(found.filter { !LoginForm.isFrontmost($0, in: tree) }.prefix(maximumFields + 1))
    }

    /// The rules a field passes before it is typed into, read again on the screen just before each field.
    public static func check(_ field: UINode, _ target: LoginFillTarget, in tree: UITree, replace: Bool, revealed: RevealedSecrets? = nil) throws {
        let name = describe(field)
        switch target {
        case .password:
            guard field.isSecure else { throw kindRefusal(field, target: target, revealed: revealed) }
        case .identity:
            if field.isSecure {
                throw LoginFillRefusal(kind: .visible, message: "\(name) is a password field, not an email or username field. Nothing was typed. Fill it with --fill password.")
            }
            if revealed?.matches(field) == true {
                throw LoginFillRefusal(kind: .revealed, message: "\(name) was a password field that a show-password toggle turned into plain text. Nothing was typed.")
            }
            guard field.role == .textField || field.role == .searchField else { throw kindRefusal(field, target: target, revealed: revealed) }
        }
        guard field.id?.isEmpty == false || field.label?.isEmpty == false else {
            throw LoginFillRefusal(kind: .unnamed, message: "The \(target.fieldName) has no id or label, so it cannot be typed into. Nothing was typed.")
        }
        // The email or username is no secret and always replaces what the field holds, which a simulator cannot tell from its placeholder.
        guard target == .password else { return }
        switch content(of: field, bulletsAreText: bulletsAreText(in: tree)) {
        case .empty:
            return
        case .plain:
            throw LoginFillRefusal(kind: .revealed, message: "\(name) shows its text instead of bullets, so the password would show on screen. Nothing was typed. Hide the password first.")
        case .bullets:
            guard !replace else { return }
            throw LoginFillRefusal(
                kind: .holdsText,
                message: "\(name) already holds text, so nothing was typed. Pass --replace to type the saved password over it."
            )
        }
    }

    /// A show-password toggle that is on, or a plain text field where the tree cache saw a password field: either shows the password once typed.
    public static func refuseRevealed(in tree: UITree, revealed: RevealedSecrets?) throws {
        let nodes = LoginForm.visibleControls(in: tree)
        if let toggle = nodes.first(where: isRevealToggleOn) {
            throw LoginFillRefusal(
                kind: .revealed,
                message: "\(describe(toggle)) is on, so the password would show on screen. Nothing was typed. Turn it off, then run login again."
            )
        }
        if let revealed, let field = nodes.first(where: { revealed.matches($0) && LoginForm.isFrontmost($0, in: tree) }) {
            throw LoginFillRefusal(
                kind: .revealed,
                message: "\(describe(field)) was a password field and now shows plain text, so a show-password toggle is on. Nothing was typed. Turn it off, then run login again."
            )
        }
    }

    /// A switch, checkbox or button named to show or hide a password, that is now showing it: on, checked or selected, or named Hide.
    public static func isRevealToggleOn(_ node: UINode) -> Bool {
        guard [.switch, .checkbox, .button].contains(node.role) else { return false }
        let words = Set(LoginForm.tokens(node))
        guard words.contains("password") else { return false }
        if words.contains("hide") { return true }
        guard !words.isDisjoint(with: ["show", "reveal", "unmask", "view"]) else { return false }
        if node.state.checked == true || node.state.selected == true { return true }
        return ["1", "on", "true"].contains(node.normalizedValue?.lowercased() ?? "")
    }

    /// `id=password` or `label=Password`, for a report and the evidence run; the label as the output masks show it.
    public static func name(_ field: UINode) -> String {
        if let id = field.normalizedID { return "id=\(id)" }
        if let label = field.normalizedLabel { return "label=\(OutputMasks.current.mask.shownLabel(label, id: nil))" }
        return field.role.rawValue
    }

    enum Content {
        case empty
        case bullets
        case plain
    }

    /// Android and the iPhone runner, which drops a placeholder, show bullets only for text; an iOS simulator shows an empty field's placeholder as bullets too.
    static func bulletsAreText(in tree: UITree) -> Bool {
        guard tree.platform == .ios else { return true }
        guard case .ios(let native)? = tree.roots.first?.native else { return false }
        return native.bundleID != nil
    }

    /// A password field's text as the tree shows it. Where bullets may be the placeholder the field reads as empty and is typed over; iOS never shows a password field's text, so plain text there is the placeholder too.
    static func content(of field: UINode, bulletsAreText: Bool) -> Content {
        guard let value = field.value, !value.isEmpty else { return .empty }
        if SecureText.isMaskDots(value) { return bulletsAreText ? .bullets : .empty }
        switch field.native {
        case .ios: return .empty
        case .android(let native): return value == native.hint ? .empty : .plain
        }
    }

    private static func named(
        _ id: String, target: LoginFillTarget, in controls: [UINode], front: (UINode) -> Bool, revealed: RevealedSecrets?
    ) throws -> UINode {
        let matches = controls.filter { $0.normalizedID == id }
        guard !matches.isEmpty else {
            throw LoginFillRefusal(kind: .missing, message: "No field with id \(id) is on screen. Nothing was typed.")
        }
        let shown = matches.filter(front)
        guard let only = shown.first else {
            throw LoginFillRefusal(kind: .missing, message: "The field with id \(id) is not in front: it is covered or off screen. Nothing was typed.")
        }
        guard shown.count == 1 else {
            throw LoginFillRefusal(kind: .ambiguous, message: "\(shown.count) fields with id \(id) are in front. Nothing was typed.")
        }
        return only
    }

    private static func detected(_ target: LoginFillTarget, in controls: [UINode], front: (UINode) -> Bool) throws -> [UINode] {
        let wanted: (UINode) -> Bool = target == .password
            ? { $0.isSecure }
            : { ($0.role == .textField || $0.role == .searchField) && LoginForm.isIdentityName($0) }
        let named = controls.filter { wanted($0) && $0.enabled != false }
        let shown = named.filter(front)
        guard !shown.isEmpty else {
            if target == .password, let plain = controls.first(where: { $0.role.isTextInput && !$0.isSecure && front($0) && LoginForm.tokens($0).contains("password") }) {
                throw LoginFillRefusal(
                    kind: .visible,
                    message: "\(describe(plain)) is a text field anyone can read, not a password field, so a show-password toggle may be on. Nothing was typed."
                )
            }
            let why = named.isEmpty ? "No \(target.fieldName) is on screen." : "No \(target.fieldName) is in front: each is covered or off screen."
            throw LoginFillRefusal(kind: .missing, message: "\(why) Nothing was typed.")
        }
        switch target {
        case .password where shown.count > maximumFields:
            throw LoginFillRefusal(
                kind: .tooMany,
                message: "\(shown.count) password fields are in front (\(shown.map(name).joined(separator: ", "))), and login --fill types into at most \(maximumFields). Nothing was typed. Name one with --into-id."
            )
        case .identity where shown.count > 1:
            throw LoginFillRefusal(
                kind: .ambiguous,
                message: "\(shown.count) email or username fields are in front (\(shown.map(name).joined(separator: ", "))). Nothing was typed. Name one with --into-id."
            )
        default:
            return shown
        }
    }

    private static func kindRefusal(_ field: UINode, target: LoginFillTarget, revealed: RevealedSecrets?) -> LoginFillRefusal {
        let name = describe(field)
        if target == .password, revealed?.matches(field) == true {
            return LoginFillRefusal(kind: .revealed, message: "\(name) was a password field and now shows plain text, so a show-password toggle is on. Nothing was typed.")
        }
        if field.role.isTextInput {
            return LoginFillRefusal(kind: .visible, message: "\(name) is a text field anyone can read, not a password field, so the password was not typed there.")
        }
        return LoginFillRefusal(kind: .unreadable, message: "\(name) is a \(field.role.rawValue), so the screen does not say it is \(target == .password ? "a password field" : "a text field"). Nothing was typed.")
    }

    /// `The field id=password`, or a toggle's role and name.
    private static func describe(_ node: UINode) -> String {
        let shown = name(node)
        return node.role.isTextInput ? "The field \(shown)" : "The \(node.role.rawValue) \(shown)"
    }
}

/// How far `login --fill` got with one field. Never the text, nor how long it is.
public struct LoginFillField: Equatable, Sendable {
    /// `id=password` or `label=Password`.
    public var name: String
    public var progress: LoginFieldProgress

    public init(name: String, progress: LoginFieldProgress = .notFilled) {
        self.name = name
        self.progress = progress
    }
}

/// What `login --fill` prints: the app, the login and each field's progress, never the secret or its length.
public struct LoginFillReport: Equatable, Sendable {
    public var app: String
    public var key: String
    public var target: LoginFillTarget
    public var fields: [LoginFillField]
    public var tags: [LoginTag] = []
    public var filter: [LoginTag] = []
    /// What became of a save-password prompt after typing; nil when none showed.
    public var savePrompt: SavePromptOutcome?
    public var error: ErrorPayload?

    public init(app: String, key: String, target: LoginFillTarget, fields: [LoginFillField]) {
        self.app = app
        self.key = key
        self.target = target
        self.fields = fields
    }

    public var exitCode: OffsiderExitCode { error?.exitCode ?? .success }

    public var filled: [LoginFillField] { fields.filter { $0.progress == .filled } }

    /// The sentence a stopped fill's message ends with; nil when no field was filled.
    public var progressNote: String? {
        let names = filled.map(\.name)
        guard !names.isEmpty else { return nil }
        return "\(names.joined(separator: " and ")) \(names.count == 1 ? "was" : "were") filled."
    }

    public func textLine() -> String {
        let chosen = filter.isEmpty ? "" : " (chosen by --where \(filter.map(\.rawValue).joined(separator: " ")))"
        let what = target == .password ? "the saved password" : "the saved email or username"
        let prompt = savePrompt == .declined ? " Offsider declined the system's save-password prompt." : ""
        return "\(app) as \(LoginCredential.displayKey(key))\(chosen): typed \(what) into \(filled.map(\.name).joined(separator: " and ")). Nothing was submitted.\(prompt)"
    }

    /// Version 1: keys are only ever added.
    public func jsonLine() -> String {
        var members: [(String, OrderedJSON)] = [
            ("version", .integer(1)),
            ("ok", .bool(error == nil)),
            ("app", .string(app)),
            ("key", .string(key)),
            ("name", .string(LoginCredential.displayKey(key))),
            ("tags", .array(tags.map { .string($0.rawValue) })),
            ("fill", .string(target.rawValue)),
            ("fields", .array(fields.map { .object([("field", .string($0.name)), ("state", .string($0.progress.rawValue))]) })),
            ("submitted", .bool(false)),
        ]
        if !filter.isEmpty { members.append(("where", .array(filter.map { .string($0.rawValue) }))) }
        members.append(("savePrompt", .optional(savePrompt) { .string($0.rawValue) }))
        members.append(("exitCode", .integer(Int(exitCode.rawValue))))
        members.append(("error", .optional(error) { $0.jsonValue }))
        return OrderedJSON.object(members).rendered(compact: true)
    }
}
