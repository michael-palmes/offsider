import Foundation

/// A label for what a saved login suits: a bare word such as `beta`, or `key=value` such as `role=admin`. Never a secret.
public struct LoginTag: Hashable, Comparable, Sendable, RawRepresentable, CustomStringConvertible {
    public static let platformKey = "platform"
    public static let platforms = DevicePlatform.allCases.map(\.rawValue)
    public static let rule = "A tag is a word or key=value, such as beta or role=admin: the word or key is 1 to 32 characters from a-z, 0-9, '.', '_' and '-', the value 1 to 64 from a-z, 0-9, '.', '_', ':', '/', '+' and '-', each starting with a letter or digit, and platform takes ios or android."

    public let key: String
    public let value: String?

    /// Trims and lowercases `rawValue`. Nil when it breaks `rule`.
    public init?(rawValue: String) {
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard Self.isWord(parts[0], limit: 32, extra: "._-") else { return nil }
        if parts.count == 2 {
            guard Self.isWord(parts[1], limit: 64, extra: "._:/+-") else { return nil }
            if parts[0] == Self.platformKey, !Self.platforms.contains(parts[1]) { return nil }
            value = parts[1]
        } else {
            guard parts[0] != Self.platformKey else { return nil }
            value = nil
        }
        key = parts[0]
    }

    public init(platform: DevicePlatform) {
        key = Self.platformKey
        value = platform.rawValue
    }

    public var rawValue: String { value.map { "\(key)=\($0)" } ?? key }
    public var description: String { rawValue }

    public static func < (lhs: LoginTag, rhs: LoginTag) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Why `raw` is not a tag, naming the rule, or nil when it is one.
    public static func problem(_ raw: String) -> String? {
        guard LoginTag(rawValue: raw) == nil else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == platformKey || text.hasPrefix(platformKey + "=") {
            return "The tag \(raw) is not a platform: platform takes ios or android, such as platform=ios."
        }
        return "\(raw) is not a tag. \(rule)"
    }

    private static func isWord(_ text: String, limit: Int, extra: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (1...limit).contains(scalars.count), isAlphanumeric(scalars[0]) else { return false }
        let others = Set(extra.unicodeScalars)
        return scalars.allSatisfy { isAlphanumeric($0) || others.contains($0) }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
    }
}

/// The three free-text notes a saved login carries.
public enum LoginNote: String, CaseIterable, Sendable {
    /// Access, and when to use the login.
    case about
    /// Tests the login must not be used for.
    case avoid
    /// What the account holds now. It drifts.
    case state

    public var flag: String { "--\(rawValue)" }
}

/// Why a note cannot be saved.
public enum LoginNoteProblem: Equatable, Sendable {
    case control
    case bidi
    case tooLong
    case email

    public static let rule = "A note is one line of at most \(LoginContext.noteCharacters) characters, with no control or bidirectional formatting characters and no email address."

    public var text: String {
        switch self {
        case .control: return "holds a line break or another control character"
        case .bidi: return "holds a bidirectional formatting character"
        case .tooLong: return "is longer than \(LoginContext.noteCharacters) characters"
        case .email: return "looks like it holds an email address"
        }
    }
}

/// A usage problem in context flags or stored context. The message never repeats a password.
public struct LoginContextProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// What a saved login suits, beside its Keychain secret. It is not secret, so it never holds an email address.
public struct LoginContext: Equatable, Sendable {
    public static let version = 2
    public static let maxTags = 16
    public static let noteCharacters = 200
    public static let noteBytes = 800
    public static let storageBytes = 4096
    public static let empty = LoginContext()

    public var about: String?
    public var avoid: String?
    public var state: String?
    /// Sorted and unique.
    public private(set) var tags: [LoginTag]
    /// When the context last changed, to the second.
    public var updated: Date?
    /// Mirrors of the encrypted settings, for `status` and for asking early; the encrypted data decides.
    public var confirm: Bool
    public var devices: LoginDeviceScope

    public init(
        about: String? = nil, avoid: String? = nil, state: String? = nil, tags: [LoginTag] = [], updated: Date? = nil,
        confirm: Bool = false, devices: LoginDeviceScope = .virtual
    ) {
        self.about = about
        self.avoid = avoid
        self.state = state
        self.tags = Set(tags).sorted()
        self.updated = updated
        self.confirm = confirm
        self.devices = devices
    }

    /// This context with the mirrored settings of `stored`.
    public func mirroring(_ stored: StoredLogin) -> LoginContext {
        var next = self
        next.confirm = stored.confirm
        next.devices = stored.devices
        return next
    }

    public var isEmpty: Bool { about == nil && avoid == nil && state == nil && tags.isEmpty }

    public subscript(note: LoginNote) -> String? {
        get {
            switch note {
            case .about: return about
            case .avoid: return avoid
            case .state: return state
            }
        }
        set {
            switch note {
            case .about: about = newValue
            case .avoid: avoid = newValue
            case .state: state = newValue
            }
        }
    }

    /// Why `raw` cannot be a note, or nil when it can. Leading and trailing spaces do not count.
    public static func noteProblem(_ raw: String) -> LoginNoteProblem? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }) {
            return .control
        }
        if text.unicodeScalars.contains(where: { bidiControls.contains($0.value) }) { return .bidi }
        if text.count > noteCharacters || text.utf8.count > noteBytes { return .tooLong }
        if text.range(of: #"\S+@\S+\.\S+"#, options: .regularExpression) != nil { return .email }
        return nil
    }

    /// The note as stored: one trimmed line, or `""` to clear it.
    public static func note(_ raw: String, _ note: LoginNote) throws -> String {
        if let problem = noteProblem(raw) {
            throw LoginContextProblem("\(note.flag) \(problem.text). \(LoginNoteProblem.rule)")
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `{"v":2,...}` with empty keys and default settings left out.
    public func storageData() -> Data {
        var fields: [(String, OrderedJSON)] = [("v", .integer(Self.version))]
        for note in LoginNote.allCases {
            if let text = self[note] { fields.append((note.rawValue, .string(text))) }
        }
        if !tags.isEmpty { fields.append(("tags", .array(tags.map { .string($0.rawValue) }))) }
        if let updated { fields.append(("updated", .string(ProcessStamp.timestamp(updated)))) }
        if confirm { fields.append(("confirm", .bool(true))) }
        if devices != .virtual { fields.append(("devices", .string(devices.rawValue))) }
        return Data(OrderedJSON.object(fields).rendered(compact: true).utf8)
    }

    /// A stored context. Missing data, as on a login saved before contexts existed, reads as empty.
    public static func read(_ data: Data?) -> LoginContextRead {
        guard let data, !data.isEmpty else { return .saved(.empty) }
        guard data.count <= storageBytes, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["v"] as? Int, version >= 1
        else { return .damaged }
        if version > Self.version { return .newer(version) }
        var context = LoginContext()
        for note in LoginNote.allCases {
            guard let value = object[note.rawValue] else { continue }
            guard let text = value as? String, noteProblem(text) == nil else { return .damaged }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            context[note] = trimmed.isEmpty ? nil : trimmed
        }
        if let value = object["tags"] {
            guard let raw = value as? [String], raw.count <= maxTags else { return .damaged }
            let tags = raw.compactMap(LoginTag.init(rawValue:))
            guard tags.count == raw.count else { return .damaged }
            context.tags = Set(tags).sorted()
        }
        if let value = object["updated"] {
            guard let text = value as? String, let date = ProcessStamp.date(fromTimestamp: text) else { return .damaged }
            context.updated = date
        }
        if let value = object["confirm"] {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return .damaged }
            context.confirm = flag.boolValue
        }
        if let value = object["devices"] {
            guard let text = value as? String, let scope = LoginDeviceScope(rawValue: text) else { return .damaged }
            context.devices = scope
        }
        return .saved(context)
    }

    private static let bidiControls: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
}

/// A stored context as read. A newer Offsider's context is never overwritten.
public enum LoginContextRead: Equatable, Sendable {
    case saved(LoginContext)
    case newer(Int)
    case damaged
}

/// Changes to a context: clear tags, then untag, then tag. A note of `""` clears it.
public struct LoginContextEdit: Equatable, Sendable {
    public var about: String?
    public var avoid: String?
    public var state: String?
    public var tag: [LoginTag]
    public var untag: [LoginTag]
    public var clearTags: Bool

    public init(about: String? = nil, avoid: String? = nil, state: String? = nil, tag: [LoginTag] = [], untag: [LoginTag] = [], clearTags: Bool = false) {
        self.about = about
        self.avoid = avoid
        self.state = state
        self.tag = tag
        self.untag = untag
        self.clearTags = clearTags
    }

    public var isEmpty: Bool { about == nil && avoid == nil && state == nil && tag.isEmpty && untag.isEmpty && !clearTags }

    /// Checks raw flag values; the problem names the flag and states the rule.
    public static func parse(about: String?, avoid: String?, state: String?, tag: [String], untag: [String], clearTags: Bool) throws -> LoginContextEdit {
        func tags(_ raw: [String], flag: String) throws -> [LoginTag] {
            try raw.map { text in
                guard let parsed = LoginTag(rawValue: text) else {
                    throw LoginContextProblem("\(flag) \(LoginTag.problem(text) ?? LoginTag.rule)")
                }
                return parsed
            }
        }
        return LoginContextEdit(
            about: try about.map { try LoginContext.note($0, .about) },
            avoid: try avoid.map { try LoginContext.note($0, .avoid) },
            state: try state.map { try LoginContext.note($0, .state) },
            tag: try tags(tag, flag: "--tag"),
            untag: try tags(untag, flag: "--untag"),
            clearTags: clearTags
        )
    }

    /// `context` with this edit applied. `updated` becomes `now` only when something changed.
    public func applied(to context: LoginContext, now: Date) throws -> LoginContext {
        var tags = clearTags ? [] : context.tags
        tags.removeAll { untag.contains($0) }
        tags += tag
        var next = LoginContext(
            about: context.about, avoid: context.avoid, state: context.state, tags: tags, updated: context.updated, confirm: context.confirm, devices: context.devices
        )
        guard next.tags.count <= LoginContext.maxTags else {
            throw LoginContextProblem("A saved login holds at most \(LoginContext.maxTags) tags, and this would give it \(next.tags.count). Remove some with --untag or --clear-tags. Nothing was saved.")
        }
        for (note, text) in [(LoginNote.about, about), (.avoid, avoid), (.state, state)] {
            guard let text else { continue }
            next[note] = text.isEmpty ? nil : text
        }
        if next != context { next.updated = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)) }
        guard next.storageData().count <= LoginContext.storageBytes else {
            throw LoginContextProblem("The notes and tags come to more than \(LoginContext.storageBytes) bytes. Shorten a note or remove tags. Nothing was saved.")
        }
        return next
    }
}
