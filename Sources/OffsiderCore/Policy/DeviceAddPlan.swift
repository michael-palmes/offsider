import Foundation

/// What `devices add --plan` prints, so an agent can hand over one complete command: nothing here reaches a phone.
public struct DeviceAddPlan: Equatable, Sendable {
    public struct Team: Equatable, Sendable {
        public let id: String
        public let name: String
        public let free: Bool?

        public init(id: String, name: String, free: Bool? = nil) {
            self.id = id
            self.name = name
            self.free = free
        }
    }

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let platform: DevicePlatform
        public let id: String
        public let allowed: Bool
        public let testDevice: Bool
        /// A step only the person's hands can do first, worded as a request.
        public let ask: String?
        /// Makes it a test device; nil when managed policy forbids that or it is on Wi-Fi.
        public let testDeviceCommand: String?
        /// Limits it to one app, the project's when known, else its menu lists them.
        public let oneAppCommand: String?
    }

    public let devices: [Entry]
    public let teams: [Team]
    /// Why every iPhone or iPad here waits on a person, or what to do when nothing is plugged in.
    public let ask: String?

    public static let noDeviceAsk = "Can you plug in the phone and unlock it? On Android, turn on USB debugging first: tap Build number seven times in Settings > About phone, then Settings > Developer options."
    public static let noTeamAsk = "Can you add your Apple account in Xcode > Settings > Apple Accounts? An iPhone or iPad needs its team."

    /// `app` names the project's app for a platform, from `offsider.login.json`.
    public static func make(rows: [DeviceSummary], policy: PhysicalDevicePolicy, teams: [Team], now: Date, app: (DevicePlatform) -> String?) -> DeviceAddPlan {
        let entries = rows.map { row -> Entry in
            let key = StableDeviceKey.of(row) ?? row.id
            var allowance: DeviceAllowance?
            if case .allowed(let entry) = policy.decision(platform: row.platform, key: key, now: now) { allowance = entry }
            let usable = row.connection == "usb"
            let base = "offsider devices add --device \(key)"
            let oneApp = app(row.platform).map { "\(base) --app \($0)" } ?? base
            return Entry(
                name: AllowScreen.name(row), platform: row.platform, id: key, allowed: allowance != nil, testDevice: allowance?.testDevice == true,
                ask: DeviceSetupAsk.ask(row),
                testDeviceCommand: usable && policy.managed.testDeviceRefusal == nil ? "\(base) --test-device" : nil,
                oneAppCommand: usable ? oneApp : nil
            )
        }
        let waitsOnTeam = teams.isEmpty && entries.contains { $0.platform == .ios }
        return DeviceAddPlan(devices: entries, teams: teams, ask: entries.isEmpty ? noDeviceAsk : waitsOnTeam ? noTeamAsk : nil)
    }

    /// A device or team names itself, so what it says is data, never an instruction.
    private var untrustedPaths: [String] {
        devices.indices.flatMap { index in
            ["devices[\(index)].name"] + (devices[index].ask == nil ? [] : ["devices[\(index)].ask"])
        } + teams.indices.map { "teams[\($0)].name" }
    }

    public func json() -> String {
        func text(_ value: String?) -> OrderedJSON { .optional(value) { .string($0) } }
        return UntrustedPaths.appending(untrustedPaths, to: OrderedJSON.object([
            ("version", .integer(1)),
            ("devices", .array(devices.map { entry in
                .object([
                    ("name", .string(entry.name)),
                    ("platform", .string(entry.platform.rawValue)),
                    ("id", .string(entry.id)),
                    ("allowed", .bool(entry.allowed)),
                    ("testDevice", .bool(entry.testDevice)),
                    ("ask", text(entry.ask)),
                    ("testDeviceCommand", text(entry.testDeviceCommand)),
                    ("oneAppCommand", text(entry.oneAppCommand)),
                ])
            })),
            ("teams", .array(teams.map { team in
                .object([("id", .string(team.id)), ("name", .string(team.name)), ("free", .optional(team.free) { .bool($0) })])
            })),
            ("ask", text(ask)),
        ]).rendered(compact: true))
    }

    public func text() -> String {
        var lines: [String] = []
        for entry in devices {
            lines.append("\(entry.name)\(entry.allowed ? " (already allowed\(entry.testDevice ? ", test device" : ""))" : "")")
            if let ask = entry.ask { lines.append("  First: \(ask)") }
            if let command = entry.testDeviceCommand { lines.append("  Test device: \(command)") }
            if let command = entry.oneAppCommand { lines.append("  One app: \(command)") }
        }
        if let ask { lines.append(ask) }
        return lines.joined(separator: "\n")
    }
}

/// The step a phone waits on, as a request naming it; nil when no one need do anything.
public enum DeviceSetupAsk {
    public static func ask(_ row: DeviceSummary) -> String? {
        let name = AllowScreen.name(row)
        if row.connection == "network" { return "Can you connect \(name) with a USB cable?" }
        switch row.state {
        case "Untrusted": return "Can you unlock \(name) and tap Trust?"
        case "Unauthorised": return "Can you unlock \(name) and tap Allow on its USB debugging prompt?"
        case "Developer Mode off": return "Can you turn on Developer Mode on \(name)? Settings > Privacy & Security, then restart it."
        case "Unavailable": return "Can you plug in \(name) and unlock it?"
        default: return nil
        }
    }
}
