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
        are gone and --wait-id is on screen (without it, until the screen is still for a second). It resends \
        the link at most every 10 s, three times, while the launcher shows. An Android emulator reaches Metro \
        at 10.0.2.2 unless an adb reverse maps the port; a phone needs that reverse, which Offsider reads but \
        never sets. Exits 9 (metro_not_running) when Metro does not answer, 1 (rn_load_failed) when the app \
        shows a load error, and 5 at --timeout.

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
        let report = try await open(on: route, metro: MetroStatus(), clock: .live)
        let line = "✓ \(bundleID) loaded from Metro on port \(port) in \(WaitLoop.seconds(Double(report.elapsedMs) / 1000)) (\(report.sends) send\(report.sends == 1 ? "" : "s")\(report.launcherSeen ? ", launcher seen" : ""))"
        if json {
            print(report.jsonLine())
            print(line, to: &standardError)
        } else {
            print(line)
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
        var launcherSeen = false
        var quietSince: TimeInterval?
        var previous: AccessibilitySnapshot?
        func send() async throws {
            do {
                try await opener.openURL(url, appID: bundleID, on: device)
            } catch let error as ExpoDevClientError {
                throw CLIError(errorDescription: error.message, reason: .expoDevClientFailed)
            }
            sends += 1
            lastSend = clock.now()
            quietSince = nil
            previous = nil
        }
        try await send()

        while clock.now() < deadline {
            try await clock.sleep(Self.poll)
            guard let tree = try? await route.backend.accessibilityTree(for: device) else { continue }
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
            if ExpoDevLauncher.isLoading(tree) {
                quietSince = nil
                continue
            }
            let now = clock.now()
            if let waitID {
                guard Verifier.isOnScreen(waitID, in: tree) else { continue }
            } else {
                let snapshot = AccessibilitySnapshot(tree: tree)
                if let previous, ChangeDetector().compare(previous, snapshot) == .unchanged {
                    quietSince = quietSince ?? now
                } else {
                    quietSince = nil
                }
                previous = snapshot
                guard let since = quietSince, now - since >= Self.quietFor else { continue }
            }
            return Report(
                bundleID: bundleID, url: url, host: host, port: port, sends: sends, launcherSeen: launcherSeen, waitID: waitID,
                elapsedMs: Int(((now - start) * 1000).rounded()), bundleMs: Int(((now - lastSend) * 1000).rounded())
            )
        }
        throw CLIError(
            errorDescription: "\(bundleID) did not finish loading from Metro on \(host):\(port) within \(WaitLoop.seconds(timeout))\(launcherSeen ? "; the dev launcher was still showing" : "").",
            reason: .conditionNotMet,
            hint: "offsider describe-ui --summary --device \(device.rawValue)"
        )
    }
}
