import Foundation

/// What `offsider guard` prints: one JSON object for an agent, or a few plain lines.
public enum GuardReport {
    public static let approveCommand = "offsider guard approve"

    public static func approveCommand(app: String) -> String {
        "\(approveCommand) --app \(app)"
    }

    public struct Next: Equatable, Sendable {
        public var say: String
        public var command: String?
        /// True when only a person may run `command`, in their own terminal.
        public var person: Bool
    }

    /// What to do next for an app, in words an agent can act on without reading anything else.
    public static func next(_ set: GuardSet) -> Next {
        let approve = approveCommand(app: set.app)
        switch set.state {
        case .missing:
            return Next(say: "No guard rules for \(set.app). Write a starter file, then sharpen it with the app's own ids.", command: "offsider guard init --app \(set.app)", person: false)
        case .unapproved:
            return Next(say: "The rules are in force, and no person has approved them, so ask before driving \(set.app). Give the user this command to run in their own terminal, in the app's repository.", command: approve, person: true)
        case .changed:
            return Next(say: "The approved rules were changed outside Offsider, so nothing is sent to \(set.app). Give the user this command to run in their own terminal, in the app's repository.", command: approve, person: true)
        case .ready where !set.loosened.isEmpty:
            let count = set.loosened.count
            return Next(say: "Drive \(set.app) freely; the guard asks the person itself. The file would loosen \(count) approved rule\(count == 1 ? "" : "s"), which stay as approved until the user runs this in their own terminal.", command: approve, person: true)
        case .ready:
            return Next(say: "Drive \(set.app) freely. The guard asks the person itself at a guarded control: never ask them first, and never work around a refusal.", command: nil, person: false)
        }
    }

    static let noRules = "No guard rules here. Run `offsider guard init --app <bundle id or package>` in the app's repository."

    private static func count(_ set: GuardSet, _ action: GuardAction) -> Int {
        set.rules.filter { $0.action == action }.count
    }

    private static func text(_ value: String?) -> OrderedJSON { .optional(value) { .string($0) } }

    public static func status(_ sets: [GuardSet], file: String?, json: Bool) -> String {
        if json {
            return OrderedJSON.object([
                ("version", .integer(1)),
                ("file", text(file)),
                ("apps", .array(sets.map { set in
                    let next = next(set)
                    return .object([
                        ("app", .string(set.app)),
                        ("state", .string(set.state.rawValue)),
                        ("ask", .integer(count(set, .ask))),
                        ("never", .integer(count(set, .never))),
                        ("askUsers", .optional(set.askUsers) { .array($0.map { .string($0) }) }),
                        ("added", .integer(set.added.count)),
                        ("loosened", .array(set.loosened.map { .string($0) })),
                        ("next", .object([("say", .string(next.say)), ("command", text(next.command)), ("person", .bool(next.person))])),
                    ])
                })),
                ("next", sets.isEmpty ? .string(noRules) : .null),
            ]).rendered(compact: true)
        }
        guard !sets.isEmpty else { return noRules }
        return sets.map { set in
            let next = next(set)
            let head = "\(set.app): \(set.state.rawValue) (\(count(set, .ask)) ask, \(count(set, .never)) never)"
            return ([head, "  \(next.say)"] + (next.command.map { ["  \(next.person ? "User runs" : "Run"): \($0)"] } ?? [])).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    public static func show(_ sets: [GuardSet], json: Bool) -> String {
        if json {
            return OrderedJSON.object([("version", .integer(1)), ("apps", .array(sets.map { set in
                .object([("app", .string(set.app)), ("state", .string(set.state.rawValue))] + GuardConfig(apps: [set.app], rules: set.rules, askUsers: set.askUsers).json.dropFirst())
            }))]).rendered(compact: true)
        }
        guard !sets.isEmpty else { return noRules }
        return sets.map { set in
            var lines = ["\(set.app) (\(set.state.rawValue))"]
            for (title, action) in [("Asks you first", GuardAction.ask), ("Never tapped", .never)] {
                let rules = set.rules.filter { $0.action == action }
                lines.append("  \(title):\(rules.isEmpty ? " none" : "")")
                lines += rules.map { "    \($0.summary)" }
            }
            if let users = set.askUsers { lines.append("  Asks only for: \(users.isEmpty ? "nobody" : users.joined(separator: ", "))") }
            lines.append("  Everything else: free")
            lines += set.loosened.map { "  Waiting for approval: \($0)" }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    public static func started(path: String, config: GuardConfig, json: Bool) -> String {
        if json {
            return OrderedJSON.object([
                ("version", .integer(1)), ("file", .string(path)), ("apps", .array(config.apps.map { .string($0) })),
                ("ask", .integer(config.rules(.ask).count)), ("never", .integer(config.rules(.never).count)),
                ("todo", .array(GuardStarter.todo.map { .string($0) })),
                ("next", .object([
                    ("say", .string("Do the todo list, run `offsider guard check`, then give the user this command to run in their own terminal, in this folder.")),
                    ("command", .string(approveCommand)), ("person", .bool(true)),
                ])),
            ]).rendered(compact: true)
        }
        return (["Wrote \(path): a first draft, in force already.", "Before anyone approves it:"] + GuardStarter.todo.map { "  - \($0)" }
            + ["Then check it: offsider guard check", "Then the user runs, in this folder: \(approveCommand)"]).joined(separator: "\n")
    }

    /// `seen` holds, by rule name, whether the rule's screen and control were on the device's screen; empty without a device.
    public static func check(_ sets: [GuardSet], file: String?, front: String?, seen: [String: (screen: Bool, control: Bool)], json: Bool) -> String {
        if json {
            return OrderedJSON.object([
                ("version", .integer(1)), ("file", text(file)), ("valid", .bool(true)), ("front", text(front)),
                ("apps", .array(sets.map { set in
                    .object([("app", .string(set.app)), ("state", .string(set.state.rawValue)), ("rules", .array(set.rules.map { rule in
                        .object([
                            ("name", .string(rule.name)), ("action", .string(rule.action.rawValue)),
                            ("onScreen", .optional(seen[rule.name]) { .bool($0.control) }),
                            ("screenUp", .optional(seen[rule.name]) { .bool($0.screen) }),
                        ])
                    }))])
                })),
            ]).rendered(compact: true)
        }
        return sets.map { set in
            (["\(set.app): \(set.rules.count) rule\(set.rules.count == 1 ? "" : "s") read, \(set.state.rawValue)"] + set.rules.map { rule in
                var note = ""
                if let seen = seen[rule.name] {
                    note = seen.control ? " (on screen)" : seen.screen && rule.screen != nil ? " (its screen is up, its control is not: renamed?)" : " (not on this screen)"
                }
                return "  \(rule.action.rawValue)  \(rule.summary)\(note)"
            }).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// The few rows a person reads before approving.
    public static func approvalSummary(_ config: GuardConfig, loosened: [String]) -> [String] {
        var lines = [
            "Guard rules for \(config.apps.joined(separator: ", "))",
            "  Asks you first: \(config.rules(.ask).count)",
            "  Never tapped: \(config.rules(.never).count)",
            "  Everything else: free",
        ]
        if let users = config.askUsers { lines.append("  Asks only for: \(users.isEmpty ? "nobody" : users.joined(separator: ", "))") }
        return lines + loosened.map { "  Loosens: \($0)" }
    }

    public static func approved(_ config: GuardConfig, file: String, json: Bool) -> String {
        if json {
            return OrderedJSON.object([
                ("version", .integer(1)), ("approved", .array(config.apps.map { .string($0) })), ("rules", .integer(config.rules.count)), ("file", .string(file)),
            ]).rendered(compact: true)
        }
        let count = config.rules.count
        return "Approved \(count) rule\(count == 1 ? "" : "s") for \(config.apps.joined(separator: ", ")). Agents may now drive \(config.apps.count == 1 ? "it" : "them") freely outside those controls."
    }
}
