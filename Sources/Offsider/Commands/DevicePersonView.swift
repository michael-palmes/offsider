import Foundation
import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice

/// What the device-state, session and runner commands show a person; each command keeps its agent text as it always was.
enum DevicePersonView {
    // MARK: Output

    /// JSON as it always printed, else a person's blocks beside the agent's text, unchanged.
    static func emit(_ agent: String, json: Bool, person: [Block], notices: [Notice] = [], console: Console = .current) {
        guard !json else {
            console.data(agent + "\n")
            notices.forEach(console.notice)
            return
        }
        console.show(Page([.person(person), .agent(agent + "\n")], notices: notices))
    }

    /// Notices only a person reads: an agent already has their words on stdout, or never had them.
    static func personOnly(_ notices: [Notice], json: Bool, console: Console = .current) -> [Notice] {
        !json && console.out.profile == .person ? notices : []
    }

    /// State that outlives the command and the command that undoes it; an agent reads only `agent`, when given, as it always did.
    static func lasting(_ text: String, undo: String, label: String = "Undo", agent: String? = nil, json: Bool, console: Console = .current) -> [Notice] {
        let sentence = agent.map { $0.hasPrefix("Note: ") ? String($0.dropFirst("Note: ".count)) : $0 }
        let notice = Notice(kind: .note, text: text, agentText: sentence, mark: .keep, command: undo, label: label)
        return sentence == nil ? personOnly([notice], json: json, console: console) : [notice]
    }

    // MARK: Device state

    /// `Appearance  dark`, with a dim detail.
    static func reading(_ label: String, _ value: String, detail: String? = nil, untrusted: Bool = false) -> [Block] {
        [.fields([Field(label, Table.Cell(value, untrusted: untrusted, tag: detail))])]
    }

    /// `✅  Appearance dark` and its dim details.
    static func receipt(_ headline: String, _ details: [String?] = []) -> [Block] {
        [.outcome(.done(headline, details: details.compactMap { $0 }))]
    }

    /// `was light`, `unchanged`, or nil when the earlier value is unknown.
    static func change(from previous: String?, to current: String) -> String? {
        guard let previous else { return nil }
        return previous == current ? "unchanged" : "was \(previous)"
    }

    static func size(_ screen: UIScreenInfo?, platform: DevicePlatform) -> String? {
        screen.map { "\(DeviceSettingsReport.number($0.width)) x \(DeviceSettingsReport.number($0.height)) \(platform == .android ? "dp" : "pt")" }
    }

    static func appearance(_ reading: AppearanceReading) -> [Block] {
        switch reading {
        case .fixed(let appearance):
            return self.reading("Appearance", appearance.rawValue)
        case .scheduled(let mode):
            return self.reading("Appearance", mode, detail: mode == "auto" ? "follows the system schedule" : "follows a custom schedule", untrusted: true)
        }
    }

    static func appearanceSet(_ target: Appearance, before: AppearanceReading?) -> [Block] {
        receipt("Appearance \(target.rawValue)", [change(from: before?.name, to: target.rawValue)])
    }

    static func contentSize(_ current: ContentSizeReading, previous: ContentSizeReading?, setting: Bool) -> [Block] {
        let scale = current.fontScale.map { "font scale \(DeviceSettingsReport.number($0))" }
        guard setting else { return reading("Content size", current.category.rawValue, detail: scale) }
        return receipt("Content size \(current.category.rawValue)", [change(from: previous?.category.rawValue, to: current.category.rawValue), scale])
    }

    static func orientation(_ current: DeviceOrientation, previous: DeviceOrientation?, screen: UIScreenInfo?, platform: DevicePlatform, rotation: RotationReport? = nil, setting: Bool) -> [Block] {
        let size = size(screen, platform: platform)
        guard setting else { return reading("Orientation", current.rawValue, detail: size) }
        let restored = rotation?.restored == true ? "auto-rotate back \(rotation?.now?.autoRotate == false ? "off" : "on")" : nil
        return receipt("Orientation \(current.rawValue)", [change(from: previous?.rawValue, to: current.rawValue), size, restored])
    }

    static func posture(_ current: Posture, previous: Posture?, screen: UIScreenInfo?, platform: DevicePlatform, state: String?, angle: Int?, setting: Bool) -> [Block] {
        let display = screen.map { screen in
            [screen.resolvedDisplay(on: platform).id + " display", size(screen, platform: platform)].compactMap { $0 }.joined(separator: ", ")
        }
        let note = stateNote(current, state: state, platform: platform)
        guard setting else {
            let detail = [note, display].compactMap { $0 }.joined(separator: ", ")
            return reading("Posture", current.rawValue, detail: detail.isEmpty ? nil : detail)
        }
        return receipt("Posture \(current.rawValue)", [change(from: previous?.rawValue, to: current.rawValue), angle.map { "hinge at \($0) degrees" }, display, note])
    }

    /// `One UI TENT` or `state X` for a device state that is not the posture's own name, as the agent's line has it.
    private static func stateNote(_ posture: Posture, state: String?, platform: DevicePlatform) -> String? {
        let line = DisplayReport.postureLine(posture, screen: nil, platform: platform, state: state)
        let note = line.dropFirst("Posture: \(posture.rawValue)".count).trimmingCharacters(in: .whitespaces)
        guard note.hasPrefix("("), note.hasSuffix(")") else { return nil }
        return String(note.dropFirst().dropLast())
    }

    static func statusBarOverride(_ override: StatusBarOverride) -> [Block] {
        let line = StatusBarCommand.line(override)
        let prefix = "Status bar: "
        return receipt("Status bar overridden", [line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line])
    }

    static func statusBarCleared(platform: DevicePlatform) -> [Block] {
        receipt("Status bar cleared", [platform == .android ? "demo mode off" : nil])
    }

    static func statusBar(_ reading: StatusBarReading) -> [Block] {
        if let overrides = reading.overrides {
            guard !overrides.isEmpty else { return self.reading("Status bar", "no overrides") }
            return [.fields(overrides.sorted { $0.key < $1.key }.map { Field($0.key, Table.Cell($0.value, untrusted: true)) })]
        }
        switch reading.demoAllowed {
        case true?: return self.reading("Demo mode", "allowed", detail: "Android cannot say whether it shows")
        case false?: return self.reading("Demo mode", "not allowed")
        case nil: return self.reading("Demo mode", "never set")
        }
    }

    /// Enrolment, or the face or finger sent; `name` is Face ID, Touch ID or Fingerprint.
    static func biometric(_ action: BiometricAction, name: String, modality: BiometricModality, enrolled: Bool?, sent: String?, platform: DevicePlatform) -> [Block] {
        switch action {
        case .enrol, .unenrol:
            return receipt("\(name) \(action == .enrol ? "enrolled" : "not enrolled")")
        case .status:
            return reading(name, enrolled.map { $0 ? "enrolled" : "not enrolled" } ?? "unknown")
        case .match, .noMatch:
            let asking = "an app must be asking for it"
            guard platform == .android else {
                return receipt("Sent a \(action == .match ? "matching" : "non-matching") \(modality == .face ? "face" : "finger")", [asking])
            }
            let finger = (sent ?? "").replacingOccurrences(of: "finger touch ", with: "finger ")
            return receipt("Touched the sensor with \(finger)", [action == .noMatch ? "\(finger) is not enrolled" : nil, asking])
        }
    }

    static func stayAwake(_ reading: AwakeReading, previous: AwakeReading?, setting: Bool) -> [Block] {
        let on = !reading.stayAwake.isEmpty
        let sources = reading.stayAwake.isSuperset(of: [.ac, .usb, .wireless]) ? "while charging" : "while charging over \(reading.stayAwake.summary)"
        let caveat = on ? stayAwakeCaveat(reading) : nil
        guard setting else {
            let fields = [Field("Stay awake", Table.Cell(on ? "on " + sources : "off"))]
                + (reading.screenTimeoutSummary.map { [Field("Screen timeout", Table.Cell($0))] } ?? [])
            return [.fields(fields)] + (caveat.map { [.prose($0 + ".")] } ?? [])
        }
        let was = previous.map { $0.stayAwake.isEmpty ? "off" : "on" }
        let timeout = reading.screenTimeoutSummary.map { "screen timeout \($0)" }
        return receipt("Stay awake \(on ? "on" : "off")", [change(from: was, to: on ? "on" : "off"), on ? sources : timeout, caveat])
    }

    /// Why stay awake on has no effect, or nil when the screen stays on.
    private static func stayAwakeCaveat(_ reading: AwakeReading) -> String? {
        let timeout = reading.screenTimeoutSummary.map { "after \($0)" } ?? "when it times out"
        if reading.timeoutCappedByPolicy { return "A device policy limits the screen timeout, so Android ignores it" }
        if !reading.staysAwake, reading.screenTimeoutSummary == "never" { return "The screen timeout is never, so the screen stays on anyway" }
        if reading.charging.isEmpty { return "It is not charging, so the screen still turns off \(timeout)" }
        if !reading.staysAwake { return "It charges over \(reading.charging.summary), so the screen still turns off \(timeout)" }
        return nil
    }

    static func wake(_ outcome: WakeOutcome) -> [Block] {
        guard !outcome.sent.isEmpty else { return receipt("Screen already on and unlocked") }
        let code = outcome.previous.credential == "pin" ? "PIN" : outcome.previous.credential ?? "code"
        return receipt("Screen \(outcome.current.screenSummary)", [outcome.sent.contains("code") ? "with the saved \(code)" : nil, "was \(outcome.previous.screenSummary)"])
    }

    // MARK: Permissions

    private static func short(_ permission: String) -> String {
        permission.replacingOccurrences(of: "android.permission.", with: "")
    }

    /// `camera`, `camera and photos`, `camera, photos and location`.
    private static func list(_ names: [String]) -> String {
        names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names.joined()
    }

    /// A header and one row per service: where it is offered and, unless iOS only, the Android permissions it covers.
    static func services(_ services: [PermissionService], platform: DevicePlatform?) -> [Block] {
        let rows = services.map { service -> Table.Row in
            let platforms = [service.iosName == nil ? nil : "iOS", service.androidPermissions == nil ? nil : "Android"].compactMap { $0 }.joined(separator: ", ")
            let android = service.androidPermissions.map { $0.isEmpty ? "every runtime permission" : $0.map(short).joined(separator: ", ") }
            return Table.Row([
                Table.Cell(service.rawValue),
                platform == nil ? Table.Cell(platforms) : nil,
                platform == .ios ? nil : android.map { Table.Cell($0) },
            ])
        }
        let table = Table(columns: [
            Table.Column(agent: "SERVICE", person: 0, fit: .cut(min: 16)),
            Table.Column(agent: "PLATFORMS", person: 1, fit: .cut(min: 12), tone: .dim),
            Table.Column(agent: "ANDROID", person: 2, fit: .cut(min: 12), tone: .dim),
        ], rows: rows)
        let summary = platform.map { "\(services.count) on \($0 == .ios ? "iOS" : "Android")" } ?? "\(services.count) services"
        return [.header(Header(.key, "Permission services", [summary])), .table(table)]
    }

    static let literalNote = Notice.note("`android.permission.NAME` also names one Android permission")

    static func permissions(_ state: AndroidPackagePermissions, app: String) -> [Block] {
        guard !state.runtime.isEmpty else {
            return [.header(Header(.app, app, ["none requested"])), .prose("It requests no runtime permissions.")]
        }
        let granted = state.runtime.filter(\.granted).count
        let rows = state.runtime.map { permission in
            let services = PermissionService.allCases.filter { $0 != .all && $0.androidPermissions?.contains(permission.name) == true }.map(\.rawValue)
            return Table.Row([
                Table.Cell(short(permission.name), untrusted: true),
                Table.Cell(permission.granted ? "granted" : "denied"),
                services.isEmpty ? nil : Table.Cell(services.joined(separator: ", ")),
            ], status: permission.granted ? .ok : .off)
        }
        let table = Table(columns: [
            Table.Column(agent: "PERMISSION", person: 0, fit: .cut(min: 16)),
            Table.Column(agent: "STATE", person: 1, fit: .whole, tone: .dim),
            Table.Column(agent: "SERVICES", person: 2, fit: .optional(priority: 1), tone: .dim),
        ], rows: rows)
        let summary = [granted > 0 ? "\(granted) granted" : nil, granted < rows.count ? "\(rows.count - granted) denied" : nil].compactMap { $0 }
        return [.header(Header(.app, app, summary)), .table(table)]
    }

    /// The services that changed, those already so, and what Android did to the app.
    static func permissionChange(_ change: PermissionChange, app: String) -> [Block] {
        let verb: String
        switch change.action {
        case .grant: verb = "Granted \(list(changed(change))) to"
        case .revoke: verb = "Revoked \(list(changed(change))) from"
        case .reset: verb = "Reset \(list(changed(change))) for"
        }
        let done = change.targets.flatMap { $0.permissions.filter { $0.changed != false } }
        let asks = change.action == .reset && !done.isEmpty && done.allSatisfy { $0.current == .notDetermined } ? "it asks again on next use" : nil
        let already = change.targets.filter { $0.permissions.contains { $0.changed == false } }
            .map { "\($0.target) already \(change.action == .grant ? "granted" : "denied")" }
        let headline = changed(change).isEmpty ? "Nothing to change" : "\(verb) \(app)"
        return receipt(headline, [asks] + already + [change.appStopped ? "Android stopped the app" : nil])
    }

    /// The services and permissions at least one of whose permissions changed.
    static func changed(_ change: PermissionChange) -> [String] {
        change.targets.filter { $0.permissions.contains { $0.changed != false } }.map(\.target)
    }

    // MARK: Sessions and the runner

    /// One row per running session, a device's ID on its first row only, under a header that counts them.
    static func sessions(_ rows: [DeviceSessionRow], title: String = "Sessions", now: Date = Date()) -> [Block] {
        var table: [Table.Row] = []
        for row in rows {
            var first = true
            func add(_ kind: String, _ status: RowStatus, _ detail: String) {
                table.append(Table.Row([Table.Cell(row.device, person: first ? nil : ""), Table.Cell(kind), Table.Cell(detail)], status: status))
                first = false
            }
            if let input = row.input { add("input", warm(input.state ?? "ready"), idle(input.idleFor, of: input.idleSeconds, state: input.state ?? "ready")) }
            if let helper = row.helper { add("helper", warm(helper.state), idle(helper.idleFor, of: helper.idleSeconds, state: helper.state)) }
            if let runner = row.runner { add("runner", runnerStatus(runner), runnerDetail(runner, now: now)) }
            if let broker = row.broker { add("broker", brokerStatus(broker), brokerDetail(broker)) }
        }
        guard !table.isEmpty else { return [.header(Header(.session, title, ["none running"])), .prose("Nothing is running.")] }
        let counts: [(RowStatus, String)] = [(.on, "running"), (.starting, "starting"), (.warn, "not answering"), (.off, "stopped")]
        let summary = counts.compactMap { status, word -> String? in
            let count = table.filter { $0.status == status }.count
            return count > 0 ? "\(count) \(word)" : nil
        }
        let columns = [
            Table.Column(agent: "DEVICE", person: 0, fit: .whole),
            Table.Column(agent: "SESSION", person: 1, fit: .cut(min: 6), tone: .bold),
            Table.Column(agent: "STATE", person: 2, fit: .cut(min: 10), tone: .dim),
        ]
        return [.header(Header(.session, title, summary)), .table(Table(columns: columns, rows: table))]
    }

    /// A warm helper's or input session's state: `ready`, `starting` or `stopping`.
    private static func warm(_ state: String) -> RowStatus {
        switch state {
        case "ready": return .on
        case "stopping": return .off
        default: return .starting
        }
    }

    private static func idle(_ seconds: Int, of limit: Int, state: String) -> String {
        (state == "ready" ? "" : "\(state), ") + "idle \(seconds) s of \(limit) s"
    }

    private static func runnerStatus(_ runner: RunnerSessionRow) -> RowStatus {
        guard runner.alive else { return .off }
        return runner.record.state == .starting ? .starting : .on
    }

    private static func runnerDetail(_ runner: RunnerSessionRow, now: Date) -> String {
        guard runner.alive else { return "stopped" }
        guard runner.record.state != .starting else { return "starting" }
        return "idle \(max(0, Int(now.timeIntervalSince(runner.record.lastUsed)))) s"
    }

    private static func brokerStatus(_ broker: DeviceSessionStatus) -> RowStatus {
        guard broker.alive else { return .off }
        return broker.reply == nil ? .warn : .on
    }

    private static func brokerDetail(_ broker: DeviceSessionStatus) -> String {
        guard broker.alive else { return "stopped" }
        guard let reply = broker.reply else { return "not answering" }
        guard let stream = reply.stream else { return "running" }
        switch stream.state {
        case .live: return "streaming \(stream.width ?? 0) x \(stream.height ?? 0)"
        case .failed: return "stream failed"
        case .opening, .closed: return "stream \(stream.state.rawValue)"
        }
    }

    static func stopped(_ entries: [DeviceSessionRow.Stopped], device: String?) -> [Block] {
        guard !entries.isEmpty else { return receipt("Nothing to stop", [device.map { "no session on \($0)" }]) }
        let count = entries.reduce(0) { $0 + $1.parts.count }
        return receipt("Stopped \(count) session\(count == 1 ? "" : "s")", entries.map { "\(list($0.parts)) on \($0.device)" })
    }

    static func runnersStopped(_ udids: [String], device: String?) -> [Block] {
        guard !udids.isEmpty else { return receipt("Nothing to stop", [device.map { "no runner on \($0)" }]) }
        return receipt(udids.count == 1 ? "Stopped the runner" : "Stopped \(udids.count) runners", udids)
    }

    /// The receipt for `--clean`, and what a person should know it left: apps it could not remove, and what only Apple's site removes.
    static func cleaned(_ report: RunnerCleanupReport) -> (blocks: [Block], notices: [Notice]) {
        let builds = report.removedBuilds == 1 ? "1 cached build" : "\(report.removedBuilds) cached builds"
        let logs = report.removedLogs.isEmpty ? "" : " and \(report.removedLogs.count == 1 ? "1 log" : "\(report.removedLogs.count) logs")"
        let uninstalled = report.uninstalled.isEmpty ? nil : "uninstalled \(list(report.uninstalled))"
        let warnings = report.notUninstalled.sorted { $0.key < $1.key }.map { bundleID, detail in
            Notice.warning("Did not uninstall \(bundleID): \(TerminalText.field(detail, profile: .person))")
        }
        let remains = Notice.note("Your developer team keeps the runner's profile, App IDs and this device's registration", mark: .team)
        return (receipt("Cleaned up the runner on \(report.udid)", [uninstalled, "deleted \(builds)\(logs)"]), warnings + [remains])
    }

    static func built(udid: String, directory: URL) -> [Block] {
        receipt("Runner built for \(udid)", ["signature checked", TerminalText.homePath(directory.path)])
    }

}
