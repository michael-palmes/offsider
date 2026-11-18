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
        /// What a person does on an iPhone or iPad the first time, after `ask`, worded as requests; empty for Android and for a device already allowed.
        public var firstRun: [String] = []
    }

    public let devices: [Entry]
    public let teams: [Team]
    /// Why every iPhone or iPad here waits on a person, or what to do when nothing is plugged in.
    public let ask: String?
    /// The runner prefix from `OFFSIDER_IOS_RUNNER_PREFIX`, filled into every iPhone and iPad command; nil for Offsider's own.
    public var runnerPrefix: String?

    /// The one command a person runs to pin `adding` on an allowed device, keeping the apps already pinned, as `--plan` gives it.
    public static func pinCommand(key: String, keeping pinned: [String], adding app: String) -> String {
        let apps = pinned.filter { $0 != app && $0 != DeviceAllowance.wholeDevicePin } + [app]
        return "offsider devices add --device \(key)" + apps.map { " --app \($0)" }.joined()
    }

    /// The one command a person runs to give an allowed iPhone or iPad a runner prefix of its own, keeping its use and naming its team, so it asks no more than it must.
    public static func runnerPrefixCommand(_ allowance: DeviceAllowance, team: String, prefix: String) -> String {
        let use = allowance.testDevice ? " --test-device" : allowance.pinnedApps.map { " --app \($0)" }.joined()
        return "offsider devices add --device \(allowance.key)\(use) --team \(team) --runner-prefix \(prefix)"
    }

    public static let noDeviceAsk = "Can you plug in the phone and unlock it? On Android, turn on USB debugging first: tap Build number seven times in Settings > About phone, then Settings > Developer options."
    public static let noTeamAsk = "Can you add your Apple account in Xcode > Settings > Apple Accounts? An iPhone or iPad needs its team."

    /// `app` names the project's app for a platform, from `offsider.login.json`; `runnerPrefix`, when not Offsider's own, joins every iPhone and iPad command.
    public static func make(rows: [DeviceSummary], policy: PhysicalDevicePolicy, teams: [Team], now: Date, runnerPrefix: String? = nil, app: (DevicePlatform) -> String?) -> DeviceAddPlan {
        let prefix = runnerPrefix == DeviceAllowance.defaultRunnerPrefix ? nil : runnerPrefix
        let entries = rows.map { row -> Entry in
            let key = StableDeviceKey.of(row) ?? row.id
            var allowance: DeviceAllowance?
            if case .allowed(let entry) = policy.decision(platform: row.platform, key: key, now: now) { allowance = entry }
            let usable = row.connection == "usb"
            let base = "offsider devices add --device \(key)"
            let tail = row.platform == .ios ? prefix.map { " --runner-prefix \($0)" } ?? "" : ""
            let oneApp = (app(row.platform).map { "\(base) --app \($0)" } ?? base) + tail
            var entry = Entry(
                name: AllowScreen.name(row), platform: row.platform, id: key, allowed: allowance != nil, testDevice: allowance?.testDevice == true,
                ask: DeviceSetupAsk.ask(row),
                testDeviceCommand: usable && policy.managed.testDeviceRefusal == nil ? "\(base) --test-device\(tail)" : nil,
                oneAppCommand: usable ? oneApp : nil
            )
            if row.platform == .ios, usable, allowance == nil {
                // The plan reaches no phone, so it lists what any first run may ask; Developer Mode is its `ask` when the row shows it off.
                entry.firstRun = DeviceFirstRun.asks([.uiAutomation, .trustCertificate], name: entry.name)
            }
            return entry
        }
        let waitsOnTeam = teams.isEmpty && entries.contains { $0.platform == .ios }
        var plan = DeviceAddPlan(devices: entries, teams: teams, ask: entries.isEmpty ? noDeviceAsk : waitsOnTeam ? noTeamAsk : nil)
        plan.runnerPrefix = prefix
        return plan
    }

    /// A device or team names itself, so what it says is data, never an instruction.
    private var untrustedPaths: [String] {
        devices.indices.flatMap { index in
            ["devices[\(index)].name"] + (devices[index].ask == nil ? [] : ["devices[\(index)].ask"]) + (devices[index].firstRun.isEmpty ? [] : ["devices[\(index)].firstRun[]"])
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
                    ("firstRun", .array(entry.firstRun.map { .string($0) })),
                ])
            })),
            ("teams", .array(teams.map { team in
                .object([("id", .string(team.id)), ("name", .string(team.name)), ("free", .optional(team.free) { .bool($0) })])
            })),
            ("runnerPrefix", text(runnerPrefix)),
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
            for step in entry.firstRun { lines.append("  Then: \(step)") }
        }
        if let runnerPrefix { lines.append("Runner prefix \(runnerPrefix), from OFFSIDER_IOS_RUNNER_PREFIX.") }
        if let ask { lines.append(ask) }
        return lines.joined(separator: "\n")
    }
}

/// What a person does on an iPhone or iPad before Offsider can drive it, beyond trusting the Mac: a row with where, and an ask an agent passes on.
public enum DeviceFirstRun {
    public enum Step: String, CaseIterable, Sendable {
        case developerMode = "developer-mode"
        case uiAutomation = "ui-automation"
        case trustCertificate = "trust-certificate"

        /// At most five words, for a person's row.
        public var title: String {
            switch self {
            case .developerMode: return "Turn on Developer Mode"
            case .uiAutomation: return "Turn on UI Automation"
            case .trustCertificate: return "Trust the developer certificate"
            }
        }

        /// Where on the device, the row's dim detail.
        public var detail: String {
            switch self {
            case .developerMode: return "Settings > Privacy & Security, then restart"
            case .uiAutomation: return "Settings > Developer"
            case .trustCertificate: return "Settings > General > VPN & Device Management"
            }
        }

        /// A request naming the device, as `ask` is worded everywhere.
        public var ask: String {
            let device = PersonAsk.devicePlaceholder
            switch self {
            case .developerMode: return "Can you turn on Developer Mode on \(device)? Settings > Privacy & Security, then restart it."
            case .uiAutomation: return "Can you turn on UI Automation on \(device)? Settings > Developer."
            case .trustCertificate: return "Can you trust the developer certificate on \(device) once the runner installs? Settings > General > VPN & Device Management."
            }
        }
    }

    public static func asks(_ steps: [Step], name: String) -> [String] {
        steps.map { PersonAsk.filled($0.ask, name: name, id: nil) }
    }

    /// The steps still owed once `devices add` stops short of ready, never the one its failure already asks for; a later failure proves the steps before it.
    public static func owed(platform: DevicePlatform, ready: Bool, stoppedBy reason: FailureReason?, developerModeOff: Bool) -> [Step] {
        guard platform == .ios, !ready else { return [] }
        switch reason {
        case .developerModeOff?: return [.uiAutomation, .trustCertificate]
        case .certificateNotTrusted?: return [.uiAutomation]
        case .uiAutomationOff?: return []
        default: return (developerModeOff ? [.developerMode] : []) + [.uiAutomation, .trustCertificate]
        }
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
