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
        the Android exception class or signal, and 5 at --timeout. --restart stops the app first (simctl \
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

        while clock.now() < deadline {
            try await clock.sleep(Self.poll)
            let read = try? await route.backend.accessibilityTree(for: device)
            try await watchApp(read)
            guard let tree = read else { continue }
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
            if let open = ExpoDevLauncher.openLinkPrompt(in: tree), let frame = open.frame {
                let point = try await route.backend.deviceCoordinates(for: [(x: frame.center.x, y: frame.center.y)], tree: tree, on: device)[0]
                try await route.backend.performTracked(.tapAt(x: point.x, y: point.y), on: device)
                continue
            }
            if ExpoDevLauncher.isLauncher(tree) {
                launcherSeen = true
                if clock.now() - lastSend >= Self.resendEvery, sends <= Self.maxResends {
                    try await send()
                }
                continue
            }
            if loading {
                quietSince = nil
                continue
            }
            let now = clock.now()
            if let waitID {
                guard Verifier.isOnScreen(waitID, in: tree) else { continue }
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
                hint: "offsider rn open --port \(port) --bundle-id \(bundleID)\(waitID.map { " --wait-id \(Self.shellWord($0))" } ?? "") --restart --device \(device.rawValue)"
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
