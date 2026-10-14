import Foundation

/// What `credential` prints. Only `set` and `status <name>` show a username. The password never is, and the JSON has no password field.
public struct CredentialReport: Equatable, Sendable {
    public static let version = 2

    public var action: String
    public var app: String
    public var key: String?
    public var username: String?
    /// Whether a credential is saved after the command. A remove leaves this false.
    public var saved: Bool
    /// True when `remove` deleted an item. The password is not involved.
    public var removed: Bool
    /// Every saved login for the app, when `status` lists them. Read from attributes, so no usernames.
    public var listed: [LoginEntry]
    /// True when the saved or shown login is the one `login` uses with no name.
    public var isDefault: Bool
    /// Other bundle ids that share this app's logins.
    public var also: [String]
    /// The app a `join` attached this id to.
    public var linked: String?
    /// The notes and tags of the one login saved, described or shown.
    public var context: LoginContext?
    /// Whether `describe` changed the context.
    public var changed: Bool?
    /// Where each login was last signed in, by raw key.
    public var signIns: [String: [LoginSignIn]]
    /// The raw key last signed in on the device in hand.
    public var signedInHere: String?
    /// Whether `status` had a device in hand, so its JSON carries `signedInHere` even when nobody is recorded.
    public var deviceInHand: Bool
    /// The `--where` tags `status` chose by, empty when none were passed.
    public var filter: [LoginTag]
    /// The device `signed-out` cleared, by its stable key, and its platform.
    public var device: String?
    public var platform: DevicePlatform?
    /// Whether `signed-out` found a record to clear; `key` names the login it held.
    public var cleared: Bool?

    public init(
        action: String,
        app: String,
        key: String? = nil,
        username: String? = nil,
        saved: Bool,
        removed: Bool = false,
        listed: [LoginEntry] = [],
        isDefault: Bool = false,
        also: [String] = [],
        linked: String? = nil,
        context: LoginContext? = nil,
        changed: Bool? = nil,
        signIns: [String: [LoginSignIn]] = [:],
        signedInHere: String? = nil,
        deviceInHand: Bool = false,
        filter: [LoginTag] = [],
        device: String? = nil,
        platform: DevicePlatform? = nil,
        cleared: Bool? = nil
    ) {
        self.action = action
        self.app = app
        self.key = key
        self.username = username
        self.saved = saved
        self.removed = removed
        self.listed = listed
        self.isDefault = isDefault
        self.also = also
        self.linked = linked
        self.context = context
        self.changed = changed
        self.signIns = signIns
        self.signedInHere = signedInHere
        self.deviceInHand = deviceInHand
        self.filter = filter
        self.device = device
        self.platform = platform
        self.cleared = cleared
    }

    var isList: Bool { action == "status" && key == nil }

    public func textLine() -> String {
        if action == "join" {
            guard let linked else { return "\(app) was not linked" }
            if saved {
                return "Linked \(app) to \(linked). login on either id uses the same saved logins."
            }
            return "\(app) already shares logins with \(linked)."
        }
        if action == "signed-out" {
            let place = "\(app) on \(device ?? "")"
            guard cleared == true, let key else { return "No sign-in was recorded for \(place). Nothing was cleared." }
            let who = key == LoginCredential.defaultAccountKey ? "the default login" : key
            return "Cleared the sign-in record of \(who) for \(place). Offsider no longer counts it as signed in there."
        }
        if isList {
            guard !listed.isEmpty else { return "\(heading): no login credential saved" }
            var lines = ["\(heading):"]
            for entry in listed {
                let mark = entry.isDefault && entry.key != LoginCredential.defaultAccountKey ? " (default)" : ""
                lines.append("\(entry.name)\(mark)")
                lines += Self.textDetails(entry.context, signIns: signIns[entry.key] ?? [])
            }
            return (lines + hereLine).joined(separator: "\n")
        }
        let shown = key.map(LoginCredential.displayKey) ?? ""
        switch action {
        case "set":
            if key == nil || key == LoginCredential.defaultAccountKey {
                return "Saved the default login for \(app) (\(username ?? "")). The password is not shown."
            }
            let role = isDefault ? " It is the default login." : ""
            return "Saved the login named \(shown) for \(app) (\(username ?? "")).\(role) The password is not shown."
        case "remove":
            if key == LoginCredential.defaultAccountKey, !removed { return "No login named default was saved for \(app)" }
            let name = key == LoginCredential.defaultAccountKey ? "default login" : "login credential \(shown)"
            return removed ? "Removed the \(name) for \(app)" : "No \(name) was saved for \(app)"
        case "describe":
            let head = changed == true
                ? "Updated the notes and tags of \(shown) for \(app)."
                : "Nothing changed: \(shown) for \(app) already has these notes and tags."
            return ([head] + Self.textDetails(context ?? .empty, signIns: [])).joined(separator: "\n")
        default:
            guard saved else {
                if key == LoginCredential.defaultAccountKey { return "No login named default is saved for \(app)." }
                return "No login credential \(shown) is saved for \(app)."
            }
            let first: String
            if !filter.isEmpty {
                first = "\(heading) \(shown)\(isDefault ? " (default)" : "") matches --where \(filter.map(\.rawValue).joined(separator: " "))"
            } else if key == LoginCredential.defaultAccountKey {
                first = "\(heading) default: \(username ?? "")"
            } else {
                first = "\(heading) \(shown)\(isDefault ? " (default)" : ""): \(username ?? "")"
            }
            return ([first] + Self.textDetails(context ?? .empty, signIns: key.flatMap { signIns[$0] } ?? []) + hereLine).joined(separator: "\n")
        }
    }

    public func jsonLine() -> String {
        var fields: [(String, OrderedJSON)] = [
            ("version", .integer(Self.version)),
            ("action", .string(action)),
            ("app", .string(app)),
        ]
        if !also.isEmpty {
            fields.append(("also", .array(also.map { .string($0) })))
        }
        if action == "join" {
            if let linked { fields.append(("linked", .string(linked))) }
            fields.append(("saved", .bool(saved)))
            return OrderedJSON.object(fields).rendered(compact: true)
        }
        if action == "signed-out" {
            fields += [
                ("device", .optional(device, OrderedJSON.string)),
                ("platform", .optional(platform?.rawValue, OrderedJSON.string)),
                ("name", .optional(key.map(LoginCredential.displayKey), OrderedJSON.string)),
                ("cleared", .bool(cleared == true)),
            ]
            return OrderedJSON.object(fields).rendered(compact: true)
        }
        let showsHere = action == "status" && (deviceInHand || signedInHere != nil)
        if showsHere {
            fields.append(("signedInHere", .optional(signedInHere.map(LoginCredential.displayKey), OrderedJSON.string)))
        }
        if !filter.isEmpty {
            fields.append(("where", .array(filter.map { .string($0.rawValue) })))
        }
        if isList {
            fields.append(("users", .array(listed.map { entry in
                var user: [(String, OrderedJSON)] = [("name", .string(entry.name)), ("default", .bool(entry.isDefault))]
                user += Self.contextFields(entry.context)
                user.append(("signedIn", Self.signInsJSON(signIns[entry.key] ?? [])))
                if showsHere { user.append(("signedInHere", .bool(entry.key == signedInHere))) }
                return .object(user)
            })))
            return OrderedJSON.object(fields).rendered(compact: true)
        }
        if let key { fields.append(("name", .string(LoginCredential.displayKey(key)))) }
        fields.append(("saved", .bool(saved)))
        if action == "remove" {
            fields.append(("removed", .bool(removed)))
            return OrderedJSON.object(fields).rendered(compact: true)
        }
        if let changed { fields.append(("changed", .bool(changed))) }
        guard saved else { return OrderedJSON.object(fields).rendered(compact: true) }
        fields.append(("default", .bool(isDefault)))
        if let username { fields.append(("username", .string(username))) }
        if let context { fields += Self.contextFields(context) }
        if action == "status" {
            fields.append(("signedIn", Self.signInsJSON(key.flatMap { signIns[$0] } ?? [])))
        }
        return OrderedJSON.object(fields).rendered(compact: true)
    }

    var heading: String {
        guard !also.isEmpty else { return app }
        return "\(app) (also \(also.joined(separator: ", ")))"
    }

    private var hereLine: [String] {
        signedInHere.map { ["Signed in here: \(LoginCredential.displayKey($0))"] } ?? []
    }

    /// `tags` always, then each note and `updated` only when set, then `devices` and `confirm` when not the defaults (virtual, false).
    static func contextFields(_ context: LoginContext) -> [(String, OrderedJSON)] {
        var fields: [(String, OrderedJSON)] = [("tags", .array(context.tags.map { .string($0.rawValue) }))]
        for note in LoginNote.allCases {
            if let text = context[note] { fields.append((note.rawValue, .string(text))) }
        }
        if let updated = context.updated { fields.append(("updated", .string(ProcessStamp.timestamp(updated)))) }
        if context.devices != .virtual { fields.append(("devices", .string(context.devices.rawValue))) }
        if context.confirm { fields.append(("confirm", .bool(true))) }
        return fields
    }

    static func signInsJSON(_ signIns: [LoginSignIn]) -> OrderedJSON {
        .array(signIns.map { signIn in
            var fields: [(String, OrderedJSON)] = [
                ("device", .string(signIn.device)),
                ("platform", .string(signIn.platform.rawValue)),
                ("since", .string(ProcessStamp.timestamp(signIn.since))),
            ]
            if let restarted = signIn.restarted { fields.append(("restarted", .bool(restarted))) }
            return .object(fields)
        })
    }

    /// One indented line per tag list, note, stamp and sign-in.
    static func textDetails(_ context: LoginContext, signIns: [LoginSignIn]) -> [String] {
        var lines: [String] = []
        if !context.tags.isEmpty { lines.append("  tags: " + context.tags.map(\.rawValue).joined(separator: " ")) }
        for note in LoginNote.allCases {
            if let text = context[note] { lines.append("  \(note.rawValue): \(text)") }
        }
        if let updated = context.updated { lines.append("  updated: \(ProcessStamp.timestamp(updated))") }
        if context.devices == .any {
            lines.append(context.confirm ? "  devices: any, asks you first" : "  devices: any, without asking first (credential describe --confirm asks)")
        } else if context.confirm {
            lines.append("  asks you first")
        }
        lines += signIns.map { "  signed in on " + signInText($0) }
        return lines
    }

    static func signInText(_ signIn: LoginSignIn) -> String {
        let restart = signIn.restarted == true ? ", before the device restarted" : ""
        return "\(signIn.device) (\(signIn.platform.rawValue)) since \(ProcessStamp.timestamp(signIn.since))\(restart)"
    }
}
