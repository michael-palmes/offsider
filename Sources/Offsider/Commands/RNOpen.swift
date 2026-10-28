import ArgumentParser
import Foundation
import OffsiderCore

struct RNOpen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Load an Expo dev client's bundle from Metro on this Mac and wait until the app is up.",
        discussion: """
        Checks that Metro answers on 127.0.0.1:<port>, sends the dev client its own link to that Metro \
        (exp+<slug>://expo-development-client/?url=...), and waits until the launcher and the Bundling banner \
        are gone and --wait-id is on screen (without it, until the screen shows something and is still for a \
        second; an empty app window, as while the bundle loads, never counts). It resends \
        the link at most every 10 s, three times, while the launcher shows. Every 2 s it also checks the app's \
        process: one seen running and then gone or replaced on two checks a second apart is a crash. An Android \
        emulator reaches Metro at 10.0.2.2 unless an adb reverse maps the port; a phone needs that reverse, which \
        Offsider reads but never sets. Exits 9 (metro_not_running) when Metro does not answer, 1 (rn_load_failed) \
        when the app shows a load error, 1 (app_crashed) when its process stops, naming the iOS crash report or \
        the Android exception class or signal, and 5 at --timeout. It stops early with exit 5 when the app holds \
        a screen without --wait-id for 15 s (naming the screen) or shows Expo's dev menu intro, 1 (person_required) \
        when a system prompt covers the app on an iOS simulator (it never answers one), and with the read's own \
        error when tree reads fail for 10 s (on Android, app_not_responding when the app in front has no window). \
        On a phone allowed for any app it reads only --bundle-id. --restart stops the app first (simctl \
        terminate or am force-stop), so the link opens it fresh; use it when a timeout reports a blank screen.

        Example:
          offsider rn open --port 8081 --bundle-id com.example.app --wait-id home-screen --device DEVICE_ID
        """
    )

    @Option(help: ArgumentHelp("Metro's port on this Mac.", valueName: "port"))
    var port: Int

    @Option(name: .customLong("bundle-id"), help: ArgumentHelp("The app's bundle ID on iOS or package on Android.", valueName: "bundle-id|package"))
    var bundleID: String

    @Option(help: ArgumentHelp("The dev client's link scheme, such as exp+my-app; read from the app when it has exactly one.", valueName: "exp+slug"))
    var scheme: String?

    @Option(name: .customLong("wait-id"), help: ArgumentHelp("Wait until the element with this id is on screen.", valueName: "id"))
    var waitID: String?

    @Option(help: ArgumentHelp("Give up after this many seconds, from 10 to 900 (default 180); a first bundle can take minutes.", valueName: "seconds"))
    var timeout: Double = 180

    @Flag(help: "Stop the app before sending the link, so it opens fresh.")
    var restart = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    static let resendEvery: TimeInterval = 10
    static let maxResends = 3
    static let quietFor: TimeInterval = 1
    static let poll: Duration = .milliseconds(500)
    static let failingFor: TimeInterval = 10
    static let otherScreenFor: TimeInterval = 15
    static let coveredFor: TimeInterval = 1

    struct Report: Equatable {
        var bundleID: String
        var url: String
        var host: String
        var port: Int
        var sends: Int
        var launcherSeen: Bool
        var waitID: String?
        var elapsedMs: Int
        var bundleMs: Int

        func jsonLine() -> String {
            let waited = waitID.map { "\"\(Self.escape($0))\"" } ?? "null"
            return #"{"version":1,"bundleId":"\#(Self.escape(bundleID))","url":"\#(Self.escape(url))","host":"\#(host)","port":\#(port),"metro":"running","sends":\#(sends),"launcherSeen":\#(launcherSeen),"waitId":\#(waited),"elapsedMs":\#(elapsedMs),"bundleMs":\#(bundleMs)}"#
        }

        private static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
    }

    func validate() throws {
        guard (1...65_535).contains(port) else {
            throw ValidationError("--port must be from 1 to 65535; got \(port).")
        }
        do {
            _ = try ExpoDevClient.validate(appID: bundleID)
        } catch let error as ExpoDevClientError {
            throw ValidationError(error.message)
        }
        if let scheme, scheme.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) == nil {
            throw ValidationError("--scheme must be a URL scheme such as exp+my-app; got '\(scheme)'.")
        }
        guard timeout.isFinite, (10...900).contains(timeout) else {
            throw ValidationError("--timeout must be from 10 to 900 seconds; got \(timeout).")
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let console = Console.current
        let report = try await console.progress("Loading \(bundleID) from Metro") { try await open(on: route, metro: MetroStatus(), clock: .live) }
        let took = WaitLoop.seconds(Double(report.elapsedMs) / 1000)
        let sends = "\(report.sends) send\(report.sends == 1 ? "" : "s")"
        let line = "✓ \(bundleID) loaded from Metro on port \(port) in \(took) (\(sends)\(report.launcherSeen ? ", launcher seen" : ""))"
        if json {
            console.data(report.jsonLine() + "\n")
            console.data(line + "\n", to: .err)
        } else {
            let details = "Port \(port), \(took), \(sends)" + (report.launcherSeen ? ", launcher seen" : "")
            console.show(InputPersonView.receipt("\(bundleID) loaded from Metro", details: [details], agent: line + "\n"))
        }
    }

    /// Checks Metro, sends the link, then polls the tree until the app is up; `metro` and `clock` let tests run without a network or real waits.
    @MainActor
    func open(on route: DeviceRouter.Route, metro: MetroStatus, clock: PollClock) async throws -> Report {
        let device = route.device
        guard let opener = route.backend as? any ExpoDevClientOpening, !device.isPhysicalIOSDevice else {
            throw CLIError(errorDescription: "rn open works on iOS simulators and Android devices; \(device.rawValue) is a physical iPhone or iPad. Open the app's dev client link there yourself.", reason: .notSupported)
        }
        // A phone allowed for any app reads only the app a command names.
        (route.backend as? any AppTargetSelecting)?.selectApp(bundleID, on: device)
        if let problem = await metro.problem(port: port) {
            throw CLIError(
                errorDescription: "Metro is not running on 127.0.0.1:\(port) (\(problem)). Ask the user to start it (npx expo start --dev-client --port \(port)), then try again.",
                reason: .metroNotRunning
            )
        }
        try await opener.prepare()
        let url: String
        let host: String
        do {
            let chosen: String
            if let scheme {
                chosen = scheme
            } else {
                chosen = try ExpoDevClient.singleScheme(try await opener.devClientSchemes(bundleID, on: device), appID: bundleID)
            }
            host = try await opener.metroHost(port: port, on: device)
            url = ExpoDevClient.devClientURL(scheme: chosen, host: host, port: port)
        } catch let error as ExpoDevClientError {
            throw CLIError(errorDescription: error.message, reason: .expoDevClientFailed)
        }

        let start = clock.now()
        let deadline = start + timeout
        var sends = 0
        var lastSend = start
        var firstSend: Date?
        var launcherSeen = false
        var quietSince: TimeInterval?
        var previous: AccessibilitySnapshot?
        var blank = false
        var bare = false
        var loading = false
        let liveness = route.backend as? any AppLivenessReading
        var watch = AppLivenessWatch()
        func send() async throws {
            do {
                try await opener.openURL(url, appID: bundleID, on: device)
            } catch let error as ExpoDevClientError {
                throw CLIError(errorDescription: error.message, reason: .expoDevClientFailed)
            }
            sends += 1
            lastSend = clock.now()
            firstSend = firstSend ?? Date()
            quietSince = nil
            previous = nil
        }
        func watchApp(_ tree: UITree?, force: Bool = false) async throws {
            guard let liveness else { return }
            let now = clock.now()
            guard force || watch.isDue(at: now) else { return }
            let reading = await liveness.appLiveness(bundleID, seen: watch.seen, tree: tree, mayList: watch.takeListing(at: now), on: device)
            guard case .crashed(let process) = watch.record(reading, at: now) else { return }
            let report = await liveness.crashReport(bundleID, process: process, since: firstSend ?? Date(), on: device)
            throw Self.crashed(bundleID, process: process, report: report, metro: "\(host):\(port)", device: device)
        }
        if restart {
            if case .running(let process) = await liveness?.appLiveness(bundleID, seen: nil, tree: nil, mayList: true, on: device) {
                watch.stopped = process
            }
            do {
                try await opener.stopApp(bundleID, on: device)
            } catch let error as ExpoDevClientError {
                throw CLIError(errorDescription: error.message, reason: .expoDevClientFailed)
            }
        }
        try await send()

        var failing: (since: TimeInterval, error: any Error)?
        var anyRead = false
        var shown: (name: String, since: TimeInterval)?
        var coveredSince: TimeInterval?
        while clock.now() < deadline {
            try await clock.sleep(Self.poll)
            let readStart = clock.now()
            let tree: UITree
            do {
                tree = try await route.backend.accessibilityTree(for: device)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await watchApp(nil)
                let since = failing?.since ?? readStart
                failing = (since, error)
                if clock.now() - since >= Self.failingFor { throw await readFailure(error, failingFor: clock.now() - since, on: route) }
                continue
            }
            failing = nil
            anyRead = true
            try await watchApp(tree)
            blank = ExpoDevLauncher.isBlank(tree)
            bare = ExpoDevLauncher.isBare(tree)
            loading = ExpoDevLauncher.isLoading(tree)
            if let failure = ExpoDevLauncher.loadError(in: tree) {
                throw CLIError(
                    errorDescription: "\(bundleID) could not load its bundle from Metro on \(host):\(port): \(failure)",
                    reason: .rnLoadFailed,
                    hint: "offsider logs --rn --device \(device.rawValue)"
                )
            }
            // Only the prompt for the link just sent is answered; a later one, perhaps for another app, is reported below.
            if let open = ExpoDevLauncher.openLinkPrompt(in: tree), let frame = open.frame, clock.now() - lastSend <= Self.resendEvery {
                let point = try await route.backend.deviceCoordinates(for: [(x: frame.center.x, y: frame.center.y)], tree: tree, on: device)[0]
                try await route.backend.performTracked(.tapAt(x: point.x, y: point.y), on: device)
                continue
            }
            if ExpoDevLauncher.isLauncher(tree) {
                launcherSeen = true
                shown = nil
                if clock.now() - lastSend >= Self.resendEvery, sends <= Self.maxResends {
                    try await send()
                }
                continue
            }
            if loading {
                quietSince = nil
                shown = nil
                continue
            }
            let now = clock.now()
            let app = watch.hasPendingMiss ? nil : watch.seen
            let found = waitID.map { Verifier.isOnScreen($0, in: tree) } ?? false
            if !found, let cover = await Self.cover(over: tree, app: app, on: route) {
                quietSince = nil
                previous = nil
                shown = nil
                let since = coveredSince ?? now
                coveredSince = since
                if now - since >= Self.coveredFor { throw covered(by: cover, device: device) }
                continue
            }
            coveredSince = nil
            if let waitID {
                guard found else {
                    let name = blank || bare || Self.isForeign(tree, app: app) ? nil : Self.topElement(of: tree)
                    shown = name.map { (name: $0, since: shown?.name == $0 ? shown?.since ?? now : now) }
                    if let shown, now - shown.since >= Self.otherScreenFor {
                        throw otherScreen(shown.name, waitID: waitID, after: "it has shown it for \(WaitLoop.seconds(Self.otherScreenFor)), so rn open stopped waiting", device: device)
                    }
                    continue
                }
            } else {
                guard !bare else {
                    quietSince = nil
                    previous = nil
                    continue
                }
                let snapshot = AccessibilitySnapshot(tree: tree)
                if let previous, ChangeDetector().compare(previous, snapshot) == .unchanged {
                    quietSince = quietSince ?? now
                } else {
                    quietSince = nil
                }
                previous = snapshot
                guard let since = quietSince, now - since >= Self.quietFor else { continue }
                // A screen gone still after a crash is the home screen, not the app.
                if !watch.readRecently(at: now, within: Self.quietFor) { try await watchApp(tree, force: true) }
                if watch.hasPendingMiss { continue }
            }
            return Report(
                bundleID: bundleID, url: url, host: host, port: port, sends: sends, launcherSeen: launcherSeen, waitID: waitID,
                elapsedMs: Int(((now - start) * 1000).rounded()), bundleMs: Int(((now - lastSend) * 1000).rounded())
            )
        }
        if let failing, !anyRead || clock.now() - failing.since >= Self.failingFor / 2 {
            throw await readFailure(failing.error, failingFor: clock.now() - failing.since, on: route)
        }
        if let waitID, let shown {
            throw otherScreen(shown.name, waitID: waitID, after: "it did not appear within \(WaitLoop.seconds(timeout))", device: device)
        }
        if loading || bare {
            let seen = loading
                ? "the Bundling banner was still showing, so the bundle is still loading. Try a longer --timeout."
                : "the app's window stayed empty, as it does while its bundle loads. Try a longer --timeout\(waitID == nil ? ", or pass --wait-id with an element of its first screen" : ""); if it never loads, run rn open again with --restart."
            throw CLIError(
                errorDescription: "\(bundleID) did not finish loading from Metro on \(host):\(port) within \(WaitLoop.seconds(timeout)): \(seen)",
                reason: .conditionNotMet,
                hint: "offsider describe-ui --summary --device \(device.rawValue)"
            )
        }
        if blank {
            throw CLIError(
                errorDescription: "\(bundleID) did not finish loading from Metro on \(host):\(port) within \(WaitLoop.seconds(timeout)): the app showed a blank screen. Run rn open again with --restart to stop the app and open it fresh.",
                reason: .conditionNotMet,
                hint: restartCommand(device: device)
            )
        }
        throw CLIError(
            errorDescription: "\(bundleID) did not finish loading from Metro on \(host):\(port) within \(WaitLoop.seconds(timeout))\(launcherSeen ? "; the dev launcher was still showing" : "").",
            reason: .conditionNotMet,
            hint: "offsider describe-ui --summary --device \(device.rawValue)"
        )
    }

    static func shellWord(_ text: String) -> String {
        text.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil ? text : ExpoDevClient.shellQuote(text)
    }

    func restartCommand(device: DeviceID) -> String {
        "offsider rn open --port \(port) --bundle-id \(bundleID)\(scheme.map { " --scheme \($0)" } ?? "")\(waitID.map { " --wait-id \(Self.shellWord($0))" } ?? "") --restart --device \(device.rawValue)"
    }

    /// The read's own error; Android's `no_window` with an app in front on a usable screen is `app_not_responding`.
    @MainActor
    func readFailure(_ error: any Error, failingFor seconds: TimeInterval, on route: DeviceRouter.Route) async -> any Error {
        guard (error as? any OffsiderFailure)?.reason == .noWindow, let package = await AppNotResponding.frontApp(on: route) else { return error }
        guard package == bundleID else { return AppNotResponding.failure(package: package, device: route.device) }
        return CLIError(
            errorDescription: "\(bundleID) is in front on \(route.device.rawValue), but Android has listed no window for it for \(WaitLoop.seconds(seconds)), so the app is not responding. Run rn open again with --restart to stop it and open it fresh.",
            reason: .appNotResponding,
            hint: restartCommand(device: route.device)
        )
    }

    enum Cover {
        case devMenuIntro
        case prompt(SystemPrompt, buttons: [String])
    }

    /// What hides the app: the dev menu's intro, or on an iOS simulator a system prompt, which another process draws.
    @MainActor
    static func cover(over tree: UITree, app: AppProcess?, on route: DeviceRouter.Route) async -> Cover? {
        if ExpoDevLauncher.isDevMenuIntro(tree) { return .devMenuIntro }
        if isForeign(tree, app: app), let pid = SimulatorAppLiveness.applicationPID(in: tree), let alert = SystemPrompt.alert(in: tree) {
            let process = await (route.backend as? any PointHitTesting)?.processName(of: pid, on: route.device)
            return .prompt(SystemPrompt(title: alert.title, process: process, pid: pid), buttons: alert.buttons)
        }
        return await SystemPromptProbe.find(in: tree, backend: route.backend, device: route.device).map { .prompt($0, buttons: []) }
    }

    /// True when an iOS tree comes from another process than the app's, as SpringBoard's does while it shows an alert.
    static func isForeign(_ tree: UITree, app: AppProcess?) -> Bool {
        guard let app, let pid = SimulatorAppLiveness.applicationPID(in: tree) else { return false }
        return pid != app.pid
    }

    /// The first element on screen with an id, else with a label, as tree output shows it.
    static func topElement(of tree: UITree) -> String? {
        let nodes = tree.roots.flatMap { $0.flattened() }.filter { node in
            node.role != .application && node.role != .window && (tree.viewport.map { node.frame?.isVisible(in: $0) == true } ?? true)
        }
        if let id = nodes.lazy.compactMap(\.normalizedID).first {
            return "id=\(TerminalText.field(id))"
        }
        let label = nodes.lazy.filter { $0.normalizedLabel != nil }.compactMap { OutputMasks.current.mask.shownLabel(of: $0) }.first
        return label.map { TerminalText.quoted(SelectorText.truncated($0)) }
    }

    func covered(by cover: Cover, device: DeviceID) -> CLIError {
        switch cover {
        case .devMenuIntro:
            return CLIError(
                errorDescription: "Expo's dev menu intro is over \(bundleID), so rn open stopped waiting. Run rn prepare once to mark it seen, then rn open again with --restart.",
                reason: .conditionNotMet,
                hint: "offsider rn prepare --bundle-id \(bundleID) --device \(device.rawValue)"
            )
        case .prompt(let prompt, let buttons):
            let choices = buttons.isEmpty ? "" : " (\(buttons.map { TerminalText.quoted(SelectorText.truncated($0)) }.joined(separator: ", ")))"
            return CLIError(
                errorDescription: "\(bundleID) is behind \(prompt.summary)\(choices), so rn open stopped waiting. It never answers a system prompt: ask the user which to choose, answer it, then run rn open again.",
                reason: .personRequired,
                hint: buttons.isEmpty ? "offsider screenshot --device \(device.rawValue)" : "offsider describe-ui --summary --device \(device.rawValue)"
            )
        }
    }

    func otherScreen(_ name: String, waitID: String, after: String, device: DeviceID) -> CLIError {
        CLIError(
            errorDescription: "\(bundleID) shows the screen with \(name), and --wait-id \(Self.shellWord(waitID)) is not on it: \(after). Pass --wait-id with an element of the screen the app opens on, or bring the app to that screen first.",
            reason: .conditionNotMet,
            hint: "offsider describe-ui --summary --device \(device.rawValue)"
        )
    }

    static func crashed(_ bundleID: String, process: AppProcess, report: AppCrashReport?, metro: String, device: DeviceID) -> CLIError {
        let detail = switch report {
        case .file(let path): " Crash report: \(path)"
        case .cause(let cause): " It stopped with \(cause)."
        case .pending(let directory): " Its crash report is not written yet; look in \(directory) for the newest one from pid \(process.pid)."
        case nil: ""
        }
        return CLIError(
            errorDescription: "\(bundleID) crashed while loading from Metro on \(metro): its process \(process.pid) stopped.\(detail)",
            reason: .appCrashed,
            hint: "offsider logs --rn --device \(device.rawValue)"
        )
    }
}
