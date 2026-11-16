import Darwin
import Foundation

/// The rules a person approved for one app, kept so a later edit of the repository's file cannot loosen them.
public struct GuardApproval: Equatable, Sendable {
    public var app: String
    public var approved: Date
    /// The file the rules came from, for messages.
    public var source: String?
    public var rules: [GuardRule]
    public var askUsers: [String]?

    public init(app: String, approved: Date, source: String? = nil, rules: [GuardRule], askUsers: [String]? = nil) {
        self.app = app
        self.approved = approved
        self.source = source
        self.rules = rules
        self.askUsers = askUsers
    }
}

/// `guards.json` in `~/.config/offsider`: one approval per app, written only by `guard approve` and `devices add`.
public struct GuardApprovals: Equatable, Sendable {
    public static let version = 1
    public static let maximumApps = 64

    public var entries: [GuardApproval]

    public init(entries: [GuardApproval] = []) {
        self.entries = entries
    }

    public static let empty = GuardApprovals()

    public var isEmpty: Bool { entries.isEmpty }
    public var apps: [String] { entries.map(\.app) }

    public func entry(app: String) -> GuardApproval? {
        entries.first { $0.app == app }
    }

    /// Approves `config` for each app it covers, replacing what was approved before.
    public func approving(_ config: GuardConfig, source: String?, now: Date) -> GuardApprovals {
        let fresh = config.apps.map { GuardApproval(app: $0, approved: now, source: source, rules: config.rules, askUsers: config.askUsers) }
        return GuardApprovals(entries: entries.filter { !config.apps.contains($0.app) } + fresh)
    }

    public func removing(app: String) -> GuardApprovals {
        GuardApprovals(entries: entries.filter { $0.app != app })
    }

    public static func parse(_ data: Data) throws -> GuardApprovals {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GuardConfigError("the file is not a JSON object") }
        guard let version = top["version"] as? NSNumber, version.intValue == Self.version else { throw GuardConfigError("version must be \(Self.version)") }
        guard let rows = top["apps"] as? [[String: Any]], rows.count <= maximumApps else { throw GuardConfigError("apps must be a list of at most \(maximumApps) approvals") }
        var entries: [GuardApproval] = []
        for (index, row) in rows.enumerated() {
            let at = "apps[\(index)]"
            guard let app = row["app"] as? String, DeviceAllowance.isAppID(app), !entries.contains(where: { $0.app == app }) else {
                throw GuardConfigError("\(at).app must be an app id, each once")
            }
            guard let stamp = row["approved"] as? String, let approved = ProcessStamp.date(fromTimestamp: stamp) else {
                throw GuardConfigError("\(at).approved must be an ISO 8601 time")
            }
            var body: [String: Any] = ["apps": [app]]
            for key in ["ask", "never", "askUsers"] where row[key] != nil { body[key] = row[key] }
            guard let bytes = try? JSONSerialization.data(withJSONObject: body) else { throw GuardConfigError("\(at) could not be read") }
            let config = try GuardConfig.parse(bytes, path: at)
            entries.append(GuardApproval(app: app, approved: approved, source: row["source"] as? String, rules: config.rules, askUsers: config.askUsers))
        }
        return GuardApprovals(entries: entries)
    }

    /// Stable, readable JSON with keys in schema order, ending in a newline.
    public func encoded() -> Data {
        let rows = entries.map { entry -> OrderedJSON in
            var fields: [(String, OrderedJSON)] = [("app", .string(entry.app)), ("approved", .string(ProcessStamp.timestamp(entry.approved)))]
            if let source = entry.source { fields.append(("source", .string(source))) }
            fields += GuardConfig(apps: [entry.app], rules: entry.rules, askUsers: entry.askUsers).json.dropFirst()
            return .object(fields)
        }
        return Data((OrderedJSON.object([("version", .integer(Self.version)), ("apps", .array(rows))]).rendered() + "\n").utf8)
    }
}

/// The approvals file as read: its entries and the bytes they came from, for the seal.
public struct GuardApprovalsSnapshot: Equatable, Sendable {
    public let approvals: GuardApprovals
    /// Empty when no file exists.
    public let data: Data

    public init(approvals: GuardApprovals, data: Data) {
        self.approvals = approvals
        self.data = data
    }

    public static let missing = GuardApprovalsSnapshot(approvals: .empty, data: Data())
}

/// Reads and writes `guards.json` as `DeviceAllowListStore` does its file: private, 0600, replaced atomically under a `flock`.
public struct GuardApprovalStore: Sendable {
    public static let fileName = "guards.json"
    public static let lockName = ".guards.lock"
    public static let maximumBytes = 1024 * 1024

    let directory: UserConfigDirectory

    public init(directory: UserConfigDirectory) {
        self.directory = directory
    }

    /// The file's path, for messages.
    public var path: String {
        ((directory.home as NSString).appendingPathComponent(UserConfigDirectory.configName) as NSString)
            .appendingPathComponent(UserConfigDirectory.offsiderName + "/" + Self.fileName)
    }

    /// The current approvals; a missing file or folder is none. Throws when the file is unsafe or does not parse.
    public func load() throws -> GuardApprovalsSnapshot {
        guard let folder = try directory.existing() else { return .missing }
        return try read(in: folder)
    }

    /// Under the lock, passes the current approvals to `change` and writes what it returns, then hands the new bytes and apps to `commit` (the seal).
    @discardableResult
    public func update(_ change: (GuardApprovals) throws -> GuardApprovals, commit: (Data, [String]) throws -> Void) throws -> GuardApprovalsSnapshot {
        let folder = try directory.ensure()
        let lockPath = (folder as NSString).appendingPathComponent(Self.lockName)
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(lockPath, uid: directory.uid)
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: lockPath) }
        }
        defer { flock(descriptor, LOCK_UN) }
        let current = (try? read(in: folder))?.approvals ?? .empty
        let next = try change(current)
        let data = next.encoded()
        try OffsiderPrivateDirectory.writeAtomically(data, named: Self.fileName, in: folder, uid: directory.uid)
        try commit(data, next.apps)
        return GuardApprovalsSnapshot(approvals: next, data: data)
    }

    private func read(in folder: String) throws -> GuardApprovalsSnapshot {
        guard let data = try OffsiderPrivateDirectory.readOwnedFile(named: Self.fileName, in: folder, maxBytes: Self.maximumBytes, uid: directory.uid) else {
            return .missing
        }
        return GuardApprovalsSnapshot(approvals: try GuardApprovals.parse(data), data: data)
    }
}

/// Where an app's guard stands, in the word `guard status` prints.
public enum GuardState: String, Sendable {
    /// No rules anywhere for the app.
    case missing
    /// A rules file exists and is enforced, and no person has approved rules for the app yet.
    case unapproved
    /// A person approved rules for the app.
    case ready
    /// The approvals file no longer matches its seal, so nothing is sent to its apps until a person approves again.
    case changed
}

/// The rules in force for one app: what a person approved, joined with the repository's file, the stricter winning.
public struct GuardSet: Equatable, Sendable {
    public var app: String
    public var state: GuardState
    public var rules: [GuardRule]
    /// The saved logins an `ask` may ask for; nil means every saved login.
    public var askUsers: [String]?
    /// Rules the file adds that no person has approved; in force already, since they only tighten.
    public var added: [GuardRule]
    /// What the file would loosen (approved rules it drops, logins it adds); not in force until a person approves.
    public var loosened: [String]

    public init(app: String, state: GuardState, rules: [GuardRule] = [], askUsers: [String]? = nil, added: [GuardRule] = [], loosened: [String] = []) {
        self.app = app
        self.state = state
        self.rules = rules
        self.askUsers = askUsers
        self.added = added
        self.loosened = loosened
    }

    /// Whether an agent may drive the app outside its guarded controls without asking first.
    public var isReady: Bool { state == .ready }

    public func mayAsk(user: String?) -> Bool {
        guard let user else { return false }
        return askUsers.map { $0.contains(user) } ?? true
    }

    /// `file` counts only when it covers `app`. An approval behind a broken seal is still enforced, and the state says so.
    public static func resolve(app: String, approval: GuardApproval?, file: GuardConfig?, sealIntact: Bool) -> GuardSet {
        let file = file.flatMap { $0.apps.contains(app) ? $0 : nil }
        var rules = approval?.rules ?? []
        let added = (file?.rules ?? []).filter { !rules.contains($0) }
        rules += added
        var loosened: [String] = []
        var askUsers = approval?.askUsers
        if let approval, let file {
            loosened = approval.rules.filter { !file.rules.contains($0) }.map { rule in
                file.rules.contains { $0.name == rule.name } ? "\(rule.name): changed, the approved rule still applies" : "\(rule.name): removed, still \(rule.action.rawValue)"
            }
            switch (approval.askUsers, file.askUsers) {
            case (let approved?, let wanted?):
                askUsers = approved.filter(wanted.contains)
                let extra = wanted.filter { !approved.contains($0) }
                if !extra.isEmpty { loosened.append("askUsers: adds \(extra.joined(separator: ", "))") }
            case (.some, nil):
                loosened.append("askUsers: removed, so every saved login could be asked for")
            case (nil, let wanted?):
                askUsers = wanted
            case (nil, nil):
                break
            }
        } else if approval == nil {
            askUsers = file?.askUsers
        }
        let state: GuardState
        if !sealIntact {
            state = .changed
        } else if approval != nil {
            state = .ready
        } else {
            state = file == nil ? .missing : .unapproved
        }
        return GuardSet(app: app, state: state, rules: rules, askUsers: askUsers, added: approval == nil ? [] : added, loosened: loosened)
    }
}
