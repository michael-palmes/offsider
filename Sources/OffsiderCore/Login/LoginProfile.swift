import Foundation

/// How `login` treats a Cloudflare Turnstile widget. `auto` handles one that is already on screen.
public enum LoginTurnstileMode: String, Equatable, Sendable, CaseIterable {
    case auto
    case required
    case off
}

/// One pinned control in `offsider.login.json`: an accessibility id, a label, or both.
public struct LoginField: Equatable, Sendable {
    public var id: String?
    public var label: String?

    public init(id: String? = nil, label: String? = nil) {
        self.id = id
        self.label = label
    }

    public var described: String {
        switch (id, label) {
        case (let id?, let label?): "id=\(id) label=\(label)"
        case (let id?, nil): "id=\(id)"
        case (nil, let label?): "label=\(label)"
        case (nil, nil): "the pinned field"
        }
    }
}

/// An app's sign-in screen, found the same way as `OFFSIDER.md`. Missing fields are detected from the tree.
/// It names the iOS bundle id, the Android package or both, so one file serves an app whose ids differ.
public struct LoginProfile: Equatable, Sendable {
    public static let fileName = "offsider.login.json"

    public var bundleID: String?
    public var package: String?
    public var identity: LoginField?
    public var password: LoginField?
    public var turnstile: LoginTurnstileMode?
    public var submit: LoginField?

    public init(bundleID: String? = nil, package: String? = nil, identity: LoginField? = nil, password: LoginField? = nil, turnstile: LoginTurnstileMode? = nil, submit: LoginField? = nil) {
        self.bundleID = bundleID
        self.package = package
        self.identity = identity
        self.password = password
        self.turnstile = turnstile
        self.submit = submit
    }

    public var appIDs: [String] { [bundleID, package].compactMap { $0 } }

    public func isFor(_ app: String) -> Bool { appIDs.contains(app) }

    public static func parse(_ data: Data) throws -> LoginProfile {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginProfileError("offsider.login.json must be a JSON object.")
        }
        let allowed: Set<String> = ["bundleId", "package", "identity", "password", "turnstile", "submit"]
        if let unknown = raw.keys.first(where: { !allowed.contains($0) }) {
            throw LoginProfileError("offsider.login.json has an unknown key \(unknown).")
        }
        let bundle = try string(raw["bundleId"]).map { try identifier($0, name: "bundleId") }
        let package = try string(raw["package"]).map { try identifier($0, name: "package") }
        guard bundle != nil || package != nil else {
            throw LoginProfileError("offsider.login.json must name bundleId, package or both.")
        }
        let turnstile: LoginTurnstileMode?
        if let value = string(raw["turnstile"]) {
            guard let mode = LoginTurnstileMode(rawValue: value) else {
                throw LoginProfileError("offsider.login.json turnstile must be auto, required or off.")
            }
            turnstile = mode
        } else if raw["turnstile"] != nil, !(raw["turnstile"] is NSNull) {
            throw LoginProfileError("offsider.login.json turnstile must be auto, required or off.")
        } else {
            turnstile = nil
        }
        return LoginProfile(
            bundleID: bundle,
            package: package,
            identity: try field(raw["identity"], name: "identity"),
            password: try field(raw["password"], name: "password"),
            turnstile: turnstile,
            submit: try field(raw["submit"], name: "submit")
        )
    }

    private static func field(_ value: Any?, name: String) throws -> LoginField? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw LoginProfileError("offsider.login.json \(name) must be an object with id or label.")
        }
        let allowed: Set<String> = ["id", "label"]
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
            throw LoginProfileError("offsider.login.json \(name) has an unknown key \(unknown).")
        }
        let id = try optionalText(object["id"], name: "\(name).id")
        let label = try optionalText(object["label"], name: "\(name).label")
        guard id != nil || label != nil else {
            throw LoginProfileError("offsider.login.json \(name) must set id or label.")
        }
        return LoginField(id: id, label: label)
    }

    private static func optionalText(_ value: Any?, name: String) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else {
            throw LoginProfileError("offsider.login.json \(name) must be a string.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LoginProfileError("offsider.login.json \(name) must not be empty.") }
        return trimmed
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func identifier(_ text: String, name: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256, trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw LoginProfileError("offsider.login.json \(name) must be a bundle id or package, such as com.example.app.")
        }
        return trimmed
    }
}

public struct LoginProfileError: Equatable, Error, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
