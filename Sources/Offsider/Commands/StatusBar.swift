import ArgumentParser
import Foundation
import OffsiderCore

struct StatusBarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status-bar",
        abstract: "Override the status bar with clean values, clear the override, or show it.",
        discussion: """
        override with no options sets 9:41, a full battery not charging, Wi-Fi 3 bars and cellular 4 bars. \
        iOS uses `simctl status_bar`; Android uses System UI demo mode, which `clear` exits, deleting the \
        sysui_demo_allowed setting (the override's --json reports its earlier value). Android cannot report whether \
        demo mode is showing, only whether it is allowed.

        Examples:
          offsider status-bar override --device DEVICE_ID
          offsider status-bar override --time 10:30 --battery 50 --charging --wifi off --device DEVICE_ID
          offsider status-bar clear --device DEVICE_ID
        """
    )

    enum Action: String, CaseIterable {
        case override
        case clear
        case show
    }

    @Argument(help: ArgumentHelp("override, clear or show.", valueName: "action"))
    var action: String

    @Option(name: .customLong("time"), help: ArgumentHelp("The clock, HH:MM (default 9:41).", valueName: "HH:MM"))
    var time: String?

    @Option(name: .customLong("battery"), help: ArgumentHelp("Battery level, 0 to 100 (default 100).", valueName: "percent"))
    var battery: Int?

    @Flag(name: .customLong("charging"), inversion: .prefixedNo, help: "Show the battery charging (default not charging).")
    var charging: Bool?

    @Option(name: .customLong("wifi"), help: ArgumentHelp("Wi-Fi bars, 0 to 3, or off (default 3).", valueName: "off|0-3"))
    var wifi: String?

    @Option(name: .customLong("cellular"), help: ArgumentHelp("Cellular bars, 0 to 4, or off (default 4).", valueName: "off|0-4"))
    var cellular: String?

    @Option(name: .customLong("operator"), help: ArgumentHelp("The carrier name (iOS only; default empty).", valueName: "text"))
    var operatorName: String?

    @Option(name: .customLong("data-network"), help: ArgumentHelp("wifi, 5g, lte, 4g, 3g or none (default wifi).", valueName: "type"))
    var dataNetwork: String?

    @Option(name: .customLong("notifications"), help: ArgumentHelp("Notification icons, shown or hidden (Android only; default hidden).", valueName: "shown|hidden"))
    var notifications: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        _ = try plan()
    }

    func plan() throws -> (Action, StatusBarOverride?) {
        try CLIError.refuseOnPhone(deviceOption.id, command: "status-bar", alternative: "Use an iOS simulator for a clean status bar.")
        guard let parsed = Action(rawValue: action.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("Unknown action '\(action)'. Use override, clear or show.")
        }
        let given = time != nil || battery != nil || charging != nil || wifi != nil || cellular != nil || operatorName != nil || dataNetwork != nil || notifications != nil
        guard parsed == .override else {
            if given { throw ValidationError("Status bar options go with override, not \(parsed.rawValue).") }
            return (parsed, nil)
        }
        let platform = DeviceIDClassifier.classify(deviceOption.id).platform
        if operatorName != nil, platform == .android { throw ValidationError("--operator is iOS only: Android demo mode has no carrier name.") }
        if notifications != nil, platform == .ios { throw ValidationError("--notifications is Android only: the iOS status bar shows no notification icons.") }
        var override = StatusBarOverride()
        do {
            if let time { override.time = try StatusBarOverride.parseTime(time) }
            if let wifi { override.wifiBars = try StatusBarOverride.parseBars(wifi, option: "--wifi", maximum: 3) }
            if let cellular { override.cellularBars = try StatusBarOverride.parseBars(cellular, option: "--cellular", maximum: 4) }
        } catch let error as DeviceSettingsError {
            throw ValidationError(error.message)
        }
        if let battery {
            guard (0...100).contains(battery) else { throw ValidationError("--battery takes 0 to 100; got \(battery).") }
            override.batteryLevel = battery
        }
        if let charging { override.charging = charging }
        if let operatorName { override.operatorName = operatorName }
        if let dataNetwork {
            guard let network = StatusBarDataNetwork(rawValue: dataNetwork.lowercased()) else {
                throw ValidationError("--data-network takes wifi, 5g, lte, 4g, 3g or none; got \(dataNetwork).")
            }
            override.dataNetwork = network
        }
        if let notifications {
            switch notifications.lowercased() {
            case "shown": override.notificationsHidden = false
            case "hidden": override.notificationsHidden = true
            default: throw ValidationError("--notifications takes shown or hidden; got \(notifications).")
            }
        }
        return (parsed, override)
    }

    func run() async throws {
        let (action, override) = try plan()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger, locking: action != .show)
        try await route.backend.prepare()
        let id = try await route.backend.requireBootedDevice(route.device).id
        guard let backend = route.backend as? any StatusBarControlling else {
            throw CLIError(errorDescription: "status-bar is not available for \(id.rawValue).", reason: .notSupported)
        }
        print(try await Self.report(action, override: override, json: json, on: id, backend: backend))
    }

    @MainActor
    static func report(_ action: Action, override: StatusBarOverride?, json: Bool, on device: DeviceID, backend: any StatusBarControlling) async throws -> String {
        switch action {
        case .override:
            let override = override ?? StatusBarOverride()
            let previous = try await backend.overrideStatusBar(override, on: device)
            return json ? DeviceStateReport.statusBar("override", override: override, current: nil, previous: previous, on: device) : line(override)
        case .clear:
            try await backend.clearStatusBar(on: device)
            if json { return DeviceStateReport.statusBar("clear", override: nil, current: nil, previous: nil, on: device) }
            return device.platform == .android ? "Status bar: demo mode off" : "Status bar: overrides cleared"
        case .show:
            let reading = try await backend.statusBar(on: device)
            return json ? DeviceStateReport.statusBar("show", override: nil, current: reading, previous: nil, on: device) : line(reading)
        }
    }

    static func line(_ override: StatusBarOverride) -> String {
        let bars: (Int?, String) -> String = { bars, name in bars.map { "\(name) \($0) bar\($0 == 1 ? "" : "s")" } ?? "\(name) off" }
        let battery = "battery \(override.batteryLevel) % \(override.charging ? "charging" : "not charging")"
        return "Status bar: \(override.time), \(battery), \(bars(override.wifiBars, "Wi-Fi")), \(bars(override.cellularBars, "cellular"))"
    }

    static func line(_ reading: StatusBarReading) -> String {
        if let overrides = reading.overrides {
            guard !overrides.isEmpty else { return "Status bar: no overrides" }
            return "Status bar overrides: " + overrides.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        switch reading.demoAllowed {
        case true?: return "Status bar: demo mode allowed (Android cannot report whether it is showing)"
        case false?: return "Status bar: demo mode not allowed"
        case nil: return "Status bar: demo mode never set"
        }
    }
}
