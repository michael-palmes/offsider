import Foundation

/// What `credential` prints. The username may be shown. The password never is, and the JSON has no password field.
public struct CredentialReport: Equatable, Sendable {
    public var action: String
    public var app: String
    public var key: String?
    public var username: String?
    /// Whether a credential is saved after the command. A remove leaves this false.
    public var saved: Bool
    /// True when `remove` deleted an item. The password is not involved.
    public var removed: Bool
    /// Every credential for the app, when `status` was asked with no key.
    public var listed: [LoginCredentialSummary]
    /// True when the saved or shown login is the one `login` uses with no tag.
    public var isDefault: Bool
    /// Other bundle ids that share this app's logins.
    public var also: [String]
    /// The app a `join` attached this id to.
    public var linked: String?

    public init(
        action: String,
        app: String,
        key: String? = nil,
        username: String? = nil,
        saved: Bool,
        removed: Bool = false,
        listed: [LoginCredentialSummary] = [],
        isDefault: Bool = false,
        also: [String] = [],
        linked: String? = nil
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
    }

    public func textLine() -> String {
        if action == "join" {
            guard let linked else { return "\(app) was not linked" }
            if saved {
                return "Linked \(app) to \(linked). login on either id uses the same saved logins."
            }
            return "\(app) already shares logins with \(linked)."
        }
        if action == "status", key == nil {
            guard !listed.isEmpty else { return "\(heading): no login credential saved" }
            let lines = listed.map { entry in
                let mark = entry.isDefault && entry.key != LoginCredential.defaultAccountKey ? " (default)" : ""
                return "\(LoginCredential.displayKey(entry.key))\(mark) \(entry.username)"
            }
            return "\(heading):\n" + lines.joined(separator: "\n")
        }
        let shown = key.map(LoginCredential.displayKey) ?? ""
        switch action {
        case "set":
            if key == nil || key == LoginCredential.defaultAccountKey {
                return "Saved the default login for \(app) (\(username ?? "")). The password is not shown."
            }
            let role = isDefault ? " It is the default login." : ""
            return "Saved tag \(shown) for \(app) (\(username ?? "")).\(role) The password is not shown."
        case "remove":
            let name = key == LoginCredential.defaultAccountKey ? "default login" : "login credential \(shown)"
            return removed ? "Removed the \(name) for \(app)" : "No \(name) was saved for \(app)"
        default:
            guard saved, let username else { return "No login credential \(shown) is saved for \(app)." }
            if key == LoginCredential.defaultAccountKey {
                return "\(heading) default: \(username)"
            }
            let mark = isDefault ? " (default)" : ""
            return "\(heading) tag \(shown)\(mark): \(username)"
        }
    }

    public func jsonLine() -> String {
        var fields: [(String, OrderedJSON)] = [
            ("version", .integer(1)),
            ("action", .string(action)),
            ("app", .string(app)),
        ]
        if !also.isEmpty {
            fields.append(("also", .array(also.map { .string($0) })))
        }
        if let linked { fields.append(("linked", .string(linked))) }
        if action == "join" {
            fields.append(("saved", .bool(saved)))
        } else if key == nil, action == "status" {
            fields.append(("credentials", .array(listed.map { entry in
                .object([
                    ("key", .string(LoginCredential.displayKey(entry.key))),
                    ("default", .bool(entry.isDefault)),
                    ("username", .string(entry.username)),
                    ("saved", .bool(true)),
                ])
            })))
        } else if action != "join" {
            if let key { fields.append(("key", .string(LoginCredential.displayKey(key)))) }
            if isDefault { fields.append(("default", .bool(true))) }
            if let username { fields.append(("username", .string(username))) }
            fields.append(("saved", .bool(saved)))
        }
        return OrderedJSON.object(fields).rendered(compact: true)
    }

    private var heading: String {
        guard !also.isEmpty else { return app }
        return "\(app) (also \(also.joined(separator: ", ")))"
    }
}
