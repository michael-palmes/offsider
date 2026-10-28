import ArgumentParser
import Foundation
import OffsiderCore

struct NotificationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notifications",
        abstract: "List the notifications one Android app has posted, or wait for one.",
        discussion: """
        Reads only --app's notifications, picked on the device so no other app's text crosses the cable: Android 11 \
        and later read each of the app's records by its key (`cmd notification list`, then `get`); Android 8 to 10 \
        filter `dumpsys notification --noredact` on the device to the app's records. It prints each one's title, \
        text, big text, sub-text, channel and post time, with one-time codes, card numbers, wallet addresses and \
        recovery phrases hidden as describe-ui hides them. --wait polls once a second until a title or text holds \
        the given text (case-insensitive, matched after hiding), exiting 5 at --timeout. On a physical phone the \
        app must be one the allowance permits. iOS offers no way to read posted notifications (not_supported).

        Examples:
          offsider notifications --app com.example.app --device DEVICE_ID --json
          offsider notifications --app com.example.app --wait 'Order filled' --timeout 60 --device DEVICE_ID
        """
    )

    @Option(
        name: .customLong("app"),
        help: ArgumentHelp("The app's package (default offsider.login.json's, else a phone's only pinned app).", valueName: "bundle-id")
    )
    var app: String?

    @Option(help: ArgumentHelp("Wait until a notification's title or text holds this text, ignoring case.", valueName: "text"))
    var wait: String?

    @Option(help: ArgumentHelp("With --wait: seconds to wait, from 1 to 600 (default 30).", valueName: "seconds"))
    var timeout: Double?

    static let defaultTimeout: Double = 30

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: ReadDeviceOption

    func validate() throws {
        if let app {
            do {
                _ = try ExpoDevClient.validate(appID: app)
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        }
        if let wait, wait.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--wait needs text to look for.")
        }
        guard let timeout else { return }
        guard wait != nil else { throw ValidationError("--timeout needs --wait.") }
        guard timeout.isFinite, (1...600).contains(timeout) else {
            throw ValidationError("--timeout must be from 1 to 600 seconds; got \(DeviceSettingsReport.number(timeout)).")
        }
    }

    func run() async throws {
        let rawID = deviceOption.id
        if DeviceIDClassifier.classify(rawID).platform == .ios {
            throw CLIError(errorDescription: "notifications is Android only: iOS offers no way to read an app's posted notifications. Check the screen with describe-ui or screenshot instead.", reason: .notSupported)
        }
        let route = try await DeviceRouter.route(rawID, logger: OffsiderLogger())
        let app = try Self.app(app, route: route)
        let clock = ContinuousClock()
        let limit = timeout ?? Self.defaultTimeout
        let deadline = clock.now + .seconds(limit)
        let (snapshot, listed) = try await Console.current.progress(wait.map { "Waiting for \(TerminalText.quoted($0))" } ?? "Reading \(app)'s notifications") {
            guard let reader = route.backend as? any PostedNotificationReading else {
                throw CLIError(errorDescription: "notifications is not available for \(route.device.rawValue).", reason: .notSupported)
            }
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            while true {
                let snapshot = try await reader.notifications(of: app, on: id)
                let hidden = snapshot.notifications.map { $0.redacted() }
                guard let wait else { return (snapshot, hidden) }
                if let match = hidden.first(where: { $0.notification.contains(wait) }) { return (snapshot, [match]) }
                guard clock.now + .seconds(1) < deadline else {
                    throw CLIError(
                        errorDescription: "No notification from \(app) held \(TerminalText.quoted(wait)) within \(DeviceSettingsReport.number(limit)) s (\(hidden.count) posted). Check that the app may post (`offsider permission show --app \(app) --device \(route.device.rawValue)` on Android 13 and later) and that the push was sent.",
                        reason: .conditionNotMet
                    )
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
        let shown = listed.map(\.notification)
        let redacted = listed.reduce(0) { $0 + $1.count }
        if redacted > 0 {
            Console.current.notice(.note("Hid \(redacted) value\(redacted == 1 ? "" : "s"), such as one-time codes, in \(app)'s notifications."))
        }
        let text = json
            ? NotificationReport.json(shown, app: app, source: snapshot.source, redacted: redacted, matched: wait, on: route.device)
            : Self.lines(shown, app: app, waited: wait)
        DevicePersonView.emit(text, json: json, person: Self.person(shown, app: app, waited: wait), console: .current)
    }

    /// `--app`, else offsider.login.json's package, else the allowance's only pinned app; on a phone the allowance must permit it.
    static func app(_ explicit: String?, route: DeviceRouter.Route, gate: DevicePolicyGate = .current, profile: () -> LoginProfile? = { (try? LoginProfiles.load(project: nil, warn: { _ in })) ?? nil }) throws -> String {
        let pinned = route.allowance.flatMap { $0.pinnedApps.count == 1 ? $0.pinnedApps[0] : nil }
        guard let app = explicit ?? profile()?.package.flatMap({ $0.isEmpty ? nil : $0 }) ?? pinned else {
            throw CLIError(
                errorDescription: "notifications needs the app: pass --app <package>, or name it in offsider.login.json.",
                reason: .usage,
                hint: "offsider notifications --app <package> --device \(route.device.rawValue)"
            )
        }
        if let allowance = route.allowance { try gate.requireApp(app, on: allowance) }
        return app
    }

    static func lines(_ notifications: [PostedNotification], app: String, waited: String?) -> String {
        guard !notifications.isEmpty else { return "\(app) has no notifications posted." }
        let head = waited.map { "Found \(TerminalText.quoted($0)) in a notification from \(app):" } ?? "\(app): \(notifications.count) notification\(notifications.count == 1 ? "" : "s")"
        let rows = notifications.map { notification -> String in
            let parts = [notification.title, notification.text ?? notification.bigText, notification.subText].compactMap { $0 }.map { TerminalText.quoted($0) }
            let details = [notification.channel.map { "channel \(TerminalText.field($0))" }, notification.postedAt.map { "posted \(ProcessStamp.timestamp($0))" }, notification.ongoing ? "ongoing" : nil].compactMap { $0 }
            return "  " + parts.joined(separator: " · ") + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
        }
        return ([head] + rows).joined(separator: "\n")
    }

    static func person(_ notifications: [PostedNotification], app: String, waited: String?) -> [Block] {
        let summary = waited == nil ? ["\(notifications.count) posted"] : ["found"]
        guard !notifications.isEmpty else { return [.header(Header(.app, app, ["none posted"])), .prose("It has no notifications showing.")] }
        let table = Table(columns: [
            Table.Column(agent: "TITLE", person: 0, fit: .cut(min: 12)),
            Table.Column(agent: "TEXT", person: 1, fit: .cut(min: 16), tone: .dim),
            Table.Column(agent: "POSTED", person: 2, fit: .optional(priority: 1), tone: .dim),
        ], rows: notifications.map { notification in
            Table.Row([
                Table.Cell(notification.title ?? "", untrusted: true),
                Table.Cell(notification.text ?? notification.bigText ?? "", untrusted: true),
                notification.postedAt.map { Table.Cell(ProcessStamp.timestamp($0)) },
            ])
        })
        return [.header(Header(.app, app, summary)), .table(table)]
    }
}
