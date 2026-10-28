import Foundation
import OffsiderCore

extension IOSBackend: AppLifecycleControlling {
    func appInfo(_ app: String, on id: DeviceID) async throws -> AppInfo {
        let bundleID = try ExpoDevClient.validate(appID: app)
        let result = try await Self.simctl(SimulatorApps.appInfoArguments(udid: id.rawValue, bundleID: bundleID))
        guard result.status == 0 else { throw Self.failure(result, bundleID: bundleID, on: id, doing: "read") }
        guard let info = SimulatorApps.info(result.stdout, bundleID: bundleID) else {
            throw AppLifecycleError(.failed, "simctl appinfo printed nothing Offsider could read for \(bundleID) on simulator \(id.rawValue).")
        }
        return info
    }

    func launchApp(_ app: String, restart: Bool, on id: DeviceID) async throws -> AppLaunch {
        let bundleID = try ExpoDevClient.validate(appID: app)
        let running = restart ? nil : await Self.runningPID(bundleID, on: id)
        let result = try await Self.simctl(SimulatorApps.launchArguments(udid: id.rawValue, bundleID: bundleID, restart: restart))
        guard result.status == 0 else { throw Self.failure(result, bundleID: bundleID, on: id, doing: "launch") }
        let pid = SimulatorApps.launchedPID(result.stdout, bundleID: bundleID)
        let start: AppStart = restart ? .cold : (running != nil && running == pid ? .warm : .cold)
        return AppLaunch(app: bundleID, start: start, restarted: restart, pid: pid)
    }

    func terminateApp(_ app: String, on id: DeviceID) async throws -> AppStop {
        let bundleID = try ExpoDevClient.validate(appID: app)
        let result = try await Self.simctl(ExpoDevClient.iosTerminateArguments(udid: id.rawValue, bundleID: bundleID))
        if result.status == 0 { return AppStop(app: bundleID, wasRunning: true) }
        if SimulatorApps.nothingToTerminate(status: result.status, stderr: result.stderr) {
            try await requireInstalled(bundleID, on: id)
            return AppStop(app: bundleID, wasRunning: false)
        }
        throw Self.failure(result, bundleID: bundleID, on: id, doing: "stop")
    }

    /// iOS hands the link to whichever app claims it, so the named app must be in front afterwards for the open to count.
    func openLink(_ url: String, in app: String, restart: Bool, on id: DeviceID) async throws -> AppLaunch {
        let bundleID = try ExpoDevClient.validate(appID: app)
        let link = try AppLink.validate(url)
        let name = try await appInfo(bundleID, on: id).name
        var running = await Self.runningPID(bundleID, on: id)
        if restart, running != nil {
            _ = try await Self.simctl(ExpoDevClient.iosTerminateArguments(udid: id.rawValue, bundleID: bundleID))
            running = nil
        }
        let result = try await Self.simctl(ExpoDevClient.iosOpenURLArguments(udid: id.rawValue, url: link), timeout: 30)
        if SimulatorApps.linkUnclaimed(status: result.status, stderr: result.stderr) {
            throw AppLifecycleError(.linkNotHandled, "No app on simulator \(id.rawValue) claims this link, so iOS opened nothing. Check the link's scheme against \(bundleID)'s URL types.")
        }
        guard result.status == 0 else { throw Self.failure(result, bundleID: bundleID, on: id, doing: "open the link in") }
        try await requireInFront(bundleID, name: name, on: id)
        let pid = await Self.runningPID(bundleID, on: id)
        return AppLaunch(app: bundleID, start: running != nil && running == pid ? .warm : .cold, restarted: restart, pid: pid)
    }

    static let frontChecks = (reads: 2, every: Duration.milliseconds(400), within: Duration.seconds(5))

    /// The app in front on two reads in a row; iOS 27's `Open in “<app>”?` is answered once, and only when it names this app.
    private func requireInFront(_ bundleID: String, name: String?, on id: DeviceID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.frontChecks.within
        var streak = 0
        var other: String?
        var answered = false
        while clock.now < deadline {
            try await Task.sleep(for: Self.frontChecks.every)
            guard let tree = try? await accessibilityTree(for: id), let front = try? ForegroundAppLookup.identifier(in: tree, forLogin: false) else {
                streak = 0
                continue
            }
            if !answered, let name, let open = ExpoDevLauncher.openLinkPrompt(in: tree, appName: name), let frame = open.frame {
                answered = true
                streak = 0
                let point = try await deviceCoordinates(for: [(x: frame.center.x, y: frame.center.y)], tree: tree, on: id)[0]
                try await performTracked(.tapAt(x: point.x, y: point.y), on: id)
                continue
            }
            if front == bundleID {
                streak += 1
                if streak >= Self.frontChecks.reads { return }
            } else {
                streak = 0
                other = ExpoDevLauncher.openLinkPrompt(in: tree).flatMap { _ in Self.promptTitle(in: tree) }.map { "a prompt, \(TerminalText.quoted($0))" } ?? TerminalText.quoted(front)
            }
        }
        guard let other else {
            throw AppLifecycleError(.failed, "iOS opened the link on simulator \(id.rawValue), but Offsider could not read which app is in front to confirm \(bundleID) took it. Check with `offsider describe-ui --device \(id.rawValue)`.")
        }
        if other.hasPrefix("a prompt, ") {
            throw AppLifecycleError(.linkNotHandled, "iOS answered the link with \(other), which does not name \(name ?? bundleID), so Offsider left it for a person on simulator \(id.rawValue). Send a link only \(bundleID) claims, such as its own scheme.")
        }
        throw AppLifecycleError(.linkNotHandled, "iOS opened the link in \(other), not \(bundleID), on simulator \(id.rawValue). Send a link only \(bundleID) claims, such as its own scheme.")
    }

    /// The `Open in “…”?` label of a link prompt on screen.
    private static func promptTitle(in tree: UITree) -> String? {
        tree.roots.flatMap { $0.flattened() }.compactMap { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("Open in “") && $0.hasSuffix("”?") }
    }

    private func requireInstalled(_ bundleID: String, on id: DeviceID) async throws {
        _ = try await appInfo(bundleID, on: id)
    }

    private static func runningPID(_ bundleID: String, on id: DeviceID) async -> Int? {
        guard let result = try? await simctl(SimulatorApps.launchctlListArguments(udid: id.rawValue)), result.status == 0 else { return nil }
        return SimulatorApps.runningPID(result.stdout, bundleID: bundleID)
    }

    private static func simctl(_ arguments: [String], timeout: TimeInterval = 15) async throws -> ProcessCaptureResult {
        try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: arguments, timeout: timeout)
    }

    private static func failure(_ result: ProcessCaptureResult, bundleID: String, on id: DeviceID, doing: String) -> AppLifecycleError {
        if SimulatorApps.notInstalled(stderr: result.stderr) {
            return AppLifecycleError(.notInstalled, "\(bundleID) is not installed on simulator \(id.rawValue). Install it (xcrun simctl install \(id.rawValue) <path/to/App.app>), then retry.")
        }
        let line = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(result.status)"
        return AppLifecycleError(.failed, "Could not \(doing) \(bundleID) on simulator \(id.rawValue): \(TerminalText.line(line, cap: 300))")
    }
}
