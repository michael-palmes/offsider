import Foundation

/// Devices one backend, or both iOS backends alike, could not list.
public struct ListingSkip: Sendable, Equatable {
    /// `iOS Simulators`, `iPhones and iPads`, or `iOS devices` when both failed for one reason.
    public var what: String
    public var message: String
    public var hint: String?

    public init(what: String, message: String, hint: String? = nil) {
        self.what = what
        self.message = message
        self.hint = hint
    }
}

/// What `devices` found, ready to draw.
public struct DeviceListing: Sendable {
    public var devices: [DeviceSummary]
    /// Physical devices left out because no one allowed them.
    public var hiddenPhysical: Int
    public var skipped: [ListingSkip]
    /// `OFFSIDER_DEVICE`, so the next step does not repeat it.
    public var currentDefault: String?

    public init(devices: [DeviceSummary], hiddenPhysical: Int = 0, skipped: [ListingSkip] = [], currentDefault: String? = nil) {
        self.devices = devices
        self.hiddenPhysical = hiddenPhysical
        self.skipped = skipped
        self.currentDefault = currentDefault
    }
}

/// `devices`: a person sees rows grouped by kind behind status dots; an agent the fixed table and one line per note.
public enum DevicesScreen {
    public static let groups = ["iOS Simulators", "Android Emulators", "iPhones and iPads", "Android phones"]

    /// States a person must act on before Offsider can drive the device.
    static let attention: Set<String> = ["Untrusted", "Unauthorised", "Developer Mode off", "Unavailable"]

    public static func page(_ listing: DeviceListing, now: Date = Date(), clock: (Date) -> String = DeviceLeaseRules.clock) -> Page {
        let devices = listing.devices
        let running = devices.filter { ["Booted", "Booting"].contains($0.state) }.count
        let waiting = devices.filter { status($0) == .warn }.count
        let stopped = devices.count - running - waiting
        var summary = [(running, "running"), (stopped, "shut down"), (waiting, waiting == 1 ? "needs attention" : "need attention")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        var person: [Block] = []
        if devices.isEmpty {
            summary = ["none found"]
            person = [.prose("No simulators, emulators or phones to show.")]
        }
        return Page([.person([.header(Header(.iPhone, "Devices", summary))] + person), .table(table(devices))], notices: notices(listing, now: now, clock: clock))
    }

    /// Skips, then what a person must do for a phone, who holds or leases a device, the hidden count and, for a person, the next step.
    public static func notices(_ listing: DeviceListing, now: Date = Date(), clock: (Date) -> String = DeviceLeaseRules.clock) -> [Notice] {
        var notices = listing.skipped.map(skip)
        notices += listing.devices.compactMap(phoneNotice)
        notices += listing.devices.compactMap { holderNotice($0, now: now) }
        notices += listing.devices.compactMap { leaseNotice($0, clock: clock) }
        if listing.hiddenPhysical > 0 { notices.append(hiddenNotice(listing.hiddenPhysical)) }
        if let next = nextCommand(listing) { notices.append(.next(next)) }
        return notices
    }

    /// The agent's `PLATFORM STATE ID NAME OS` table, and a person's name, OS, ID and any state that needs a look.
    public static func table(_ devices: [DeviceSummary]) -> Table {
        let columns = [
            Table.Column(agent: "PLATFORM", person: nil),
            Table.Column(agent: "STATE", person: 3, fit: .optional(priority: 2), tone: .dim),
            Table.Column(agent: "ID", person: 2, fit: .whole, tone: .dim),
            Table.Column(agent: "NAME", person: 0, fit: .cut(min: 16)),
            Table.Column(agent: "OS", person: 1, fit: .optional(priority: 1), tone: .dim),
        ]
        let rows = devices.map { device in
            Table.Row([
                Table.Cell(device.platform.rawValue),
                Table.Cell(device.state, person: ["Booted", "Shutdown"].contains(device.state) ? "" : nil),
                Table.Cell(device.id, person: device.id == device.name ? "" : nil),
                Table.Cell(device.name, untrusted: true, tag: device.allowed == true ? "allowed" : nil, whole: device.id == device.name),
                device.osVersion.map { Table.Cell($0, person: $0.hasPrefix("Android API ") ? String($0.dropFirst("Android ".count)) : nil) },
            ], status: status(device), group: group(device))
        }
        return Table(columns: columns, rows: rows, agentCap: DeviceListRenderer.maxNameCharacters, groupOrder: groups)
    }

    static func status(_ device: DeviceSummary) -> RowStatus {
        switch device.state {
        case "Booted": return .on
        case "Booting": return .starting
        case _ where attention.contains(device.state): return .warn
        default: return .off
        }
    }

    static func group(_ device: DeviceSummary) -> String {
        switch (device.kind, device.platform) {
        case (.simulator, _): return groups[0]
        case (.emulator, _), (.avd, _): return groups[1]
        case (.physical, .ios): return groups[2]
        case (.physical, .android): return groups[3]
        }
    }

    static func skip(_ skip: ListingSkip) -> Notice {
        let first = TerminalText.firstSentence(skip.message).first
        let reason = first.hasSuffix(".") ? String(first.dropLast()) : first
        return .warning("\(skip.what) skipped: \(reason)", agent: "Skipped \(skip.what): \(skip.message)", try: skip.hint)
    }

    /// What a person must do before Offsider can drive a phone, or nil when it is ready.
    static func phoneNotice(_ device: DeviceSummary) -> Notice? {
        guard device.kind == .physical else { return nil }
        if device.platform == .ios { return iosNotice(device) }
        let id = TerminalText.line(device.id)
        if device.connection == "network" {
            return .warning(
                "\(id) is on the network; connect it by USB",
                agent: "\(id) is a network adb connection, which Offsider does not drive; connect the phone over USB."
            )
        }
        guard device.state == "Unauthorised" else { return nil }
        return .warning(
            "\(id) needs USB debugging allowed: unlock it and accept the prompt",
            agent: "\(id) is unauthorised: unlock the phone and accept the \"Allow USB debugging?\" prompt, then run `offsider devices` again.",
            try: "offsider devices"
        )
    }

    private static func iosNotice(_ device: DeviceSummary) -> Notice? {
        let name = TerminalText.field(DeviceName.display(device.id, label: device.name), cap: DeviceListRenderer.maxNameCharacters)
        switch device.state {
        case "Untrusted":
            return .warning(
                "\(name) does not trust this Mac: unlock it and tap Trust",
                agent: "\(name) does not trust this Mac: unlock it and tap Trust, then run `offsider devices` again.", try: "offsider devices"
            )
        case "Developer Mode off":
            return .warning(
                "\(name) has Developer Mode off: turn it on in Settings > Privacy & Security, then restart it",
                agent: "\(name) has Developer Mode off: turn it on in Settings > Privacy & Security > Developer Mode, then restart it."
            )
        case "Preparing":
            return .note(
                "\(name) is being prepared by Xcode: keep it connected and unlocked",
                agent: "\(name) is being prepared for development by Xcode: keep it connected and unlocked until that finishes.", mark: .time
            )
        case "Unavailable":
            return .warning("\(name) is paired but not connected: plug in its cable", agent: "\(name) is paired but not connected: connect its cable and unlock it.")
        default:
            guard device.connection == "network" else { return nil }
            return .warning("\(name) is on Wi-Fi: connect its cable", agent: "\(name) is connected over Wi-Fi, which Offsider does not drive; connect its cable.")
        }
    }

    /// A device another Offsider command is driving.
    static func holderNotice(_ device: DeviceSummary, now: Date) -> Notice? {
        guard let holder = device.heldBy else { return nil }
        let command = holder.command.isEmpty ? "offsider" : "offsider \(holder.command)"
        let age = holder.startedAt.map { ", started \(max(0, Int(now.timeIntervalSince($0)))) s ago" } ?? ""
        return .note("\(device.id) is in use by `\(command)`", agent: "\(device.id) is in use by pid \(holder.pid) (\(command)\(age)).", mark: .time)
    }

    static func leaseNotice(_ device: DeviceSummary, clock: (Date) -> String) -> Notice? {
        guard let lease = device.lease else { return nil }
        let until = clock(lease.expires)
        return .note(
            "\(device.id) is leased to '\(lease.label)' until \(until)", agent: "\(device.id) is leased to '\(lease.label)' until \(until) (offsider lease show).",
            mark: .keep, see: "offsider lease show"
        )
    }

    static func hiddenNotice(_ hidden: Int) -> Notice {
        let what = hidden == 1 ? "1 physical device is" : "\(hidden) physical devices are"
        return .note(
            hidden == 1 ? "1 phone hidden until a person allows it" : "\(hidden) phones hidden until a person allows them",
            agent: "\(what) hidden because no one allowed Offsider to drive \(hidden == 1 ? "it" : "them"); a person can list them with offsider devices --physical.",
            mark: .lock, see: "offsider devices --physical"
        )
    }

    /// The one booted device to use or one to boot; with several booted, a look at the first; with nothing at all, a check of the Mac.
    static func nextCommand(_ listing: DeviceListing) -> String? {
        if let next = DeviceListOrder.nextCommand(listing.devices, currentDefault: listing.currentDefault) { return next }
        let booted = listing.devices.filter { $0.kind != .physical && $0.state == "Booted" }
        if booted.count > 1 { return "offsider describe-ui --device \(booted[0].id)" }
        return listing.devices.isEmpty && listing.skipped.isEmpty ? "offsider doctor" : nil
    }
}
