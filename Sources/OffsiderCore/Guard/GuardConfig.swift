import Foundation

/// What a guard rule does when an input would land on its control: `never` outranks `ask`.
public enum GuardAction: String, CaseIterable, Comparable, Sendable {
    case ask
    case never

    public static func < (lhs: GuardAction, rhs: GuardAction) -> Bool {
        lhs == .ask && rhs == .never
    }
}

/// Names a control or a screen's marker; a node must match every field given.
public struct GuardMatcher: Hashable, Sendable {
    public static let keys = ["id", "idPrefix", "label", "labelContains"]

    public var id: String?
    public var idPrefix: String?
    public var label: String?
    public var labelContains: String?

    public init(id: String? = nil, idPrefix: String? = nil, label: String? = nil, labelContains: String? = nil) {
        self.id = id
        self.idPrefix = idPrefix
        self.label = label
        self.labelContains = labelContains
    }

    public var isEmpty: Bool { id == nil && idPrefix == nil && label == nil && labelContains == nil }

    /// Ids are exact; labels ignore case, quote style and spacing, so a copy edit of that kind does not open the guard.
    public func matches(_ node: UINode) -> Bool {
        guard !isEmpty else { return false }
        if id != nil || idPrefix != nil {
            guard let have = node.normalizedID else { return false }
            if let id, have != id { return false }
            if let idPrefix, !have.hasPrefix(idPrefix) { return false }
        }
        if label != nil || labelContains != nil {
            guard let have = node.normalizedLabel.map(Self.folded) else { return false }
            if let label, have != Self.folded(label) { return false }
            if let labelContains, !have.contains(Self.folded(labelContains)) { return false }
        }
        return true
    }

    /// Whether text read off the screen is this matcher's label; an id alone never matches text.
    public func matches(text: String) -> Bool {
        guard id == nil, idPrefix == nil, label != nil || labelContains != nil else { return false }
        let have = Self.folded(text)
        if let label, have != Self.folded(label) { return false }
        if let labelContains, !have.contains(Self.folded(labelContains)) { return false }
        return true
    }

    public var hasLabel: Bool { label != nil || labelContains != nil }

    static func folded(_ text: String) -> String {
        SelectorText.folded(text).lowercased()
    }

    /// `id=order-confirm`, `label "Buy now"`: how a rule's target reads in a list.
    public var summary: String {
        var parts: [String] = []
        if let id { parts.append("id=\(id)") }
        if let idPrefix { parts.append("id starts \(idPrefix)") }
        if let label { parts.append("label \"\(label)\"") }
        if let labelContains { parts.append("label has \"\(labelContains)\"") }
        return parts.joined(separator: ", ")
    }

    var json: [(String, OrderedJSON)] {
        var fields: [(String, OrderedJSON)] = []
        if let id { fields.append(("id", .string(id))) }
        if let idPrefix { fields.append(("idPrefix", .string(idPrefix))) }
        if let label { fields.append(("label", .string(label))) }
        if let labelContains { fields.append(("labelContains", .string(labelContains))) }
        return fields
    }
}

/// One guarded control, or with no control a whole screen that is look-only.
public struct GuardRule: Hashable, Sendable {
    public var name: String
    public var action: GuardAction
    /// Nil guards every control on `screen`.
    public var control: GuardMatcher?
    /// When set, the rule applies only while a node matching it is on screen.
    public var screen: GuardMatcher?
    /// Controls a whole-screen rule leaves free.
    public var except: [GuardMatcher]

    public init(name: String, action: GuardAction, control: GuardMatcher? = nil, screen: GuardMatcher? = nil, except: [GuardMatcher] = []) {
        self.name = name
        self.action = action
        self.control = control
        self.screen = screen
        self.except = except
    }

    /// `Place an order: id=order-confirm`, or `Password: the screen with label "Change password"`.
    public var summary: String {
        if let control {
            return "\(name): \(control.summary)" + (screen.map { " on the screen with \($0.summary)" } ?? "")
        }
        return "\(name): the screen with \(screen?.summary ?? "")" + (except.isEmpty ? "" : " (\(except.count) left free)")
    }

    var json: OrderedJSON {
        var fields: [(String, OrderedJSON)] = [("name", .string(name))]
        fields += control?.json ?? []
        if let screen { fields.append(("screen", .object(screen.json))) }
        if !except.isEmpty { fields.append(("except", .array(except.map { .object($0.json) }))) }
        return .object(fields)
    }
}

/// A repository's `offsider.guard.json`: the controls of an app an agent asks a person before tapping, or never taps. Everything else is free.
public struct GuardConfig: Equatable, Sendable {
    public static let fileName = "offsider.guard.json"
    public static let maximumBytes = 64 * 1024
    public static let maximumRules = 64
    public static let maximumApps = 16
    public static let maximumUsers = 32
    public static let maximumNameLength = 60
    public static let maximumTextLength = 200

    /// The app ids the rules cover.
    public var apps: [String]
    public var rules: [GuardRule]
    /// The saved logins an `ask` rule may ask for; nil means every saved login.
    public var askUsers: [String]?

    public init(apps: [String], rules: [GuardRule], askUsers: [String]? = nil) {
        self.apps = apps
        self.rules = rules
        self.askUsers = askUsers
    }

    public func rules(_ action: GuardAction) -> [GuardRule] {
        rules.filter { $0.action == action }
    }

    private static let topKeys: Set<String> = ["apps", "ask", "never", "askUsers"]
    private static let ruleKeys: Set<String> = Set(GuardMatcher.keys + ["name", "screen", "except"])

    /// Strict, as `MaskConfig.parse`: unknown keys, wrong types and empty or oversized entries are refused, naming where; a `//` key is a comment.
    public static func parse(_ data: Data, path: String = fileName) throws -> GuardConfig {
        guard data.count <= maximumBytes else { throw GuardConfigError("\(path) is larger than 64 KiB.") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let line = (error as NSError).userInfo[NSDebugDescriptionErrorKey].flatMap { MaskConfig.lineNumber(in: "\($0)") }
            throw GuardConfigError("\(path)\(line.map { " line \($0)" } ?? "") is not valid JSON.")
        }
        guard let raw = object as? [String: Any] else { throw GuardConfigError("\(path) must be a JSON object.") }
        for (key, value) in raw where !topKeys.contains(key) {
            if key.hasPrefix("//") {
                guard value is String else { throw GuardConfigError("\(path): the comment \(key) must be a string.") }
                continue
            }
            throw GuardConfigError("\(path): unknown key \(key); use apps, ask, never or askUsers.")
        }
        guard let appRows = raw["apps"] as? [Any], (1...maximumApps).contains(appRows.count) else {
            throw GuardConfigError("\(path): apps must list 1 to \(maximumApps) app ids, the apps these rules cover.")
        }
        let apps = try appRows.map { row -> String in
            guard let text = row as? String, DeviceAllowance.isAppID(text) else { throw GuardConfigError("\(path): apps holds something that is not an app id.") }
            return text
        }
        guard Set(apps).count == apps.count else { throw GuardConfigError("\(path): apps repeats an app id.") }
        var askUsers: [String]?
        if let value = raw["askUsers"], !(value is NSNull) {
            guard let rows = value as? [Any], rows.count <= maximumUsers, let names = rows as? [String],
                  names.allSatisfy({ isText($0, limit: maximumNameLength) }), Set(names).count == names.count else {
                throw GuardConfigError("\(path): askUsers must list up to \(maximumUsers) saved login names, each once.")
            }
            askUsers = names
        }
        var rules: [GuardRule] = []
        for action in GuardAction.allCases {
            guard let value = raw[action.rawValue], !(value is NSNull) else { continue }
            guard let rows = value as? [Any], rows.count <= maximumRules else {
                throw GuardConfigError("\(path): \(action.rawValue) must be a list of at most \(maximumRules) rules.")
            }
            for (index, row) in rows.enumerated() {
                rules.append(try rule(row, action: action, at: "\(path): \(action.rawValue)[\(index)]"))
            }
        }
        guard !rules.isEmpty else { throw GuardConfigError("\(path): give at least one rule under ask or never.") }
        guard Set(rules.map(\.name)).count == rules.count else { throw GuardConfigError("\(path): two rules share a name; name each rule once.") }
        return GuardConfig(apps: apps, rules: rules, askUsers: askUsers)
    }

    private static func rule(_ row: Any, action: GuardAction, at: String) throws -> GuardRule {
        guard let fields = row as? [String: Any] else { throw GuardConfigError("\(at) is not an object.") }
        if let extra = Set(fields.keys).subtracting(ruleKeys).sorted().first {
            throw GuardConfigError("\(at) has the unknown key \(extra); use name, id, idPrefix, label, labelContains, screen or except.")
        }
        guard let name = fields["name"] as? String, isText(name, limit: maximumNameLength) else {
            throw GuardConfigError("\(at) needs a name of 1 to \(maximumNameLength) characters, such as \"Place an order\".")
        }
        let control = try matcher(fields, at: at)
        var screen: GuardMatcher?
        if let value = fields["screen"] {
            guard let inner = value as? [String: Any], Set(inner.keys).isSubset(of: GuardMatcher.keys) else {
                throw GuardConfigError("\(at).screen must be an object with id, idPrefix, label or labelContains.")
            }
            let parsed = try matcher(inner, at: "\(at).screen")
            guard !parsed.isEmpty else { throw GuardConfigError("\(at).screen names nothing; give it an id or a label that is on that screen.") }
            screen = parsed
        }
        var except: [GuardMatcher] = []
        if let value = fields["except"] {
            guard control.isEmpty, let rows = value as? [[String: Any]], (1...maximumRules).contains(rows.count) else {
                throw GuardConfigError("\(at).except lists the controls a whole-screen rule leaves free, so it goes on a rule with a screen and no control.")
            }
            except = try rows.enumerated().map { index, inner in
                guard Set(inner.keys).isSubset(of: GuardMatcher.keys) else { throw GuardConfigError("\(at).except[\(index)] takes id, idPrefix, label or labelContains.") }
                let parsed = try matcher(inner, at: "\(at).except[\(index)]")
                guard !parsed.isEmpty else { throw GuardConfigError("\(at).except[\(index)] names nothing.") }
                return parsed
            }
        }
        guard !control.isEmpty || screen != nil else {
            throw GuardConfigError("\(at) names no control and no screen; give it an id or label, or a screen to make look-only.")
        }
        return GuardRule(name: name, action: action, control: control.isEmpty ? nil : control, screen: screen, except: except)
    }

    private static func matcher(_ fields: [String: Any], at: String) throws -> GuardMatcher {
        func text(_ key: String) throws -> String? {
            guard let value = fields[key] else { return nil }
            guard let text = value as? String, isText(text, limit: maximumTextLength) else {
                throw GuardConfigError("\(at).\(key) must be 1 to \(maximumTextLength) characters of text.")
            }
            return text
        }
        return GuardMatcher(id: try text("id"), idPrefix: try text("idPrefix"), label: try text("label"), labelContains: try text("labelContains"))
    }

    private static func isText(_ text: String, limit: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text.count <= limit && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    var json: [(String, OrderedJSON)] {
        var fields: [(String, OrderedJSON)] = [("apps", .array(apps.map { .string($0) }))]
        if let askUsers { fields.append(("askUsers", .array(askUsers.map { .string($0) }))) }
        fields.append(("ask", .array(rules(.ask).map(\.json))))
        fields.append(("never", .array(rules(.never).map(\.json))))
        return fields
    }

    /// Stable, readable JSON with keys in schema order, ending in a newline.
    public func encoded() -> Data {
        Data((OrderedJSON.object(json).rendered() + "\n").utf8)
    }
}

public struct GuardConfigError: Equatable, Error, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
