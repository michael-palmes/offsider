import Darwin
import Foundation
import Testing

extension AndroidE2E {
    /// Pids of Offsider helpers running on the device; empty when there are none.
    static func helperPids() async throws -> String {
        try await pid(of: "offsider-helper")
    }

    static func accessibilityEnabled() async throws -> String {
        try await shell("settings get secure accessibility_enabled").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops the warm helper and waits for earlier commands' helpers to exit, so a test starts with the UiAutomation slot free.
    static func waitForNoHelper(timeout: TimeInterval = 15) async throws {
        try await run("session stop")
        guard try await eventually(timeout: timeout, { try await helperPids().isEmpty }) else {
            throw AndroidE2EError(description: "an Offsider helper was still running after \(Int(timeout)) s: \(try await helperPids())")
        }
    }

    /// True when the AVD's image lets the shell become root, as the tests that stop a process need; a Play image does not.
    static func shellCanBecomeRoot() async -> Bool {
        (try? await shell("su 0 id -u 2>/dev/null || true"))?.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    static func pid(of process: String) async throws -> String {
        try await shell("pidof \(process) || true").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ids(inDescribeUI output: String) throws -> [String] {
        guard let tree = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw AndroidE2EError(description: "describe-ui printed no JSON object")
        }
        return nodes(in: tree).compactMap { $0["id"] as? String }
    }
}

@Suite("Android helper", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidHelperTests {
    /// The SHA-256 of the dex this checkout bundles, from its manifest.
    private static func bundledDexSHA256() throws -> String {
        struct Manifest: Decodable {
            struct Dex: Decodable { let sha256: String }
            let dex: Dex
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Offsider/Resources/helper/manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data).dex.sha256
    }

    @Test("ten describe-ui runs on a warm screen use the helper, with a median under 3 s")
    func describeUITiming() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        var times: [Int] = []
        for _ in 0..<10 {
            let started = Date()
            let result = try await AndroidE2E.run("describe-ui")
            times.append(Int((Date().timeIntervalSince(started) * 1000).rounded()))
            #expect(!result.stderr.contains("Warning:"), "stderr: \(result.stderr)")
            #expect(try AndroidE2E.ids(inDescribeUI: result.stdout).contains("tap-test-area"))
        }
        let sorted = times.sorted()
        let median = (sorted[4] + sorted[5]) / 2
        print("describe-ui times (ms): \(times.map(String.init).joined(separator: ", ")); median \(median) ms")
        #expect(median < 3000, "median \(median) ms over \(times)")
    }

    @Test("with OFFSIDER_ANDROID_SESSION=off a command leaves no helper running and puts accessibility_enabled back")
    func cleansUp() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()
        let before = try await AndroidE2E.accessibilityEnabled()

        try await AndroidE2E.run("describe-ui", environment: [Self.sessionVariable: "off"])

        var pids = ""
        var after = ""
        let clean = try await AndroidE2E.eventually(timeout: 3) {
            pids = try await AndroidE2E.helperPids()
            after = try await AndroidE2E.accessibilityEnabled()
            return pids.isEmpty && after == before
        }
        #expect(clean, "helper pids '\(pids)', accessibility_enabled \(after) (was \(before))")
    }

    static let sessionVariable = "OFFSIDER_ANDROID_SESSION"

    @Test("the warm helper serves the next command, and session stop frees the slot")
    func warmHelperServesNextCommand() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()
        let before = try await AndroidE2E.accessibilityEnabled()

        try await AndroidE2E.run("describe-ui")
        let first = try await AndroidE2E.helperPids()
        #expect(!first.isEmpty, "no helper stayed warm after the command")
        #expect(try await AndroidE2E.accessibilityEnabled() == "1")
        let tapped = try await AndroidE2E.run("tap --id tap-test-area")
        #expect(tapped.stdout.contains("tap-test-area"))
        #expect(try await AndroidE2E.helperPids() == first, "the next command started another helper")
        let status = try await AndroidE2E.run("session status --json")
        #expect(status.stdout.contains(#""devicePid":\#(first)"#), "session status: \(status.stdout)")

        let stopped = try await AndroidE2E.run("session stop")
        #expect(stopped.stdout.contains("Stopped the warm helper"), "session stop: \(stopped.stdout)")
        var pids = ""
        var after = ""
        let clean = try await AndroidE2E.eventually(timeout: 3) {
            pids = try await AndroidE2E.helperPids()
            after = try await AndroidE2E.accessibilityEnabled()
            return pids.isEmpty && after == before
        }
        #expect(clean, "helper pids '\(pids)', accessibility_enabled \(after) (was \(before))")
    }

    @Test("a warm emulator's later describe-ui takes its displays from the warm helper, and reports the same screen")
    func warmHelperKeepsDisplays() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()
        let timed = ["OFFSIDER_TIMINGS": "1"]

        let first = try await AndroidE2E.run("describe-ui", environment: timed)
        let second = try await AndroidE2E.run("describe-ui", environment: timed)

        #expect(AndroidE2E.timingPhases(first.stderr).contains("display-status"), "\(AndroidE2E.timingPhases(first.stderr))")
        #expect(!AndroidE2E.timingPhases(second.stderr).contains("display-status"), "\(AndroidE2E.timingPhases(second.stderr))")
        #expect(try Self.screen(inDescribeUI: second.stdout) == Self.screen(inDescribeUI: first.stdout))
    }

    static func screen(inDescribeUI output: String) throws -> NSDictionary {
        let tree = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        return try #require(tree?["screen"] as? NSDictionary, "describe-ui printed no screen")
    }

    @Test("the warm helper stops by itself after OFFSIDER_ANDROID_SESSION_IDLE seconds")
    func warmHelperIdlesOut() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()
        let before = try await AndroidE2E.accessibilityEnabled()

        try await AndroidE2E.run("describe-ui", environment: ["OFFSIDER_ANDROID_SESSION_IDLE": "2"])
        #expect(!(try await AndroidE2E.helperPids()).isEmpty, "no helper stayed warm after the command")
        var pids = ""
        let idled = try await AndroidE2E.eventually(timeout: 10) {
            pids = try await AndroidE2E.helperPids()
            return pids.isEmpty
        }
        #expect(idled, "the warm helper was still running 10 s after a 2 s idle timeout: \(pids)")
        #expect(try await AndroidE2E.accessibilityEnabled() == before)
    }

    @Test("a command that reads with uiautomator stops the warm helper first")
    func uiautomatorStopsWarmHelper() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.run("describe-ui")
        #expect(!(try await AndroidE2E.helperPids()).isEmpty, "no helper stayed warm after the command")

        let forced = try await AndroidE2E.run("describe-ui", environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        #expect(try AndroidE2E.ids(inDescribeUI: forced.stdout).contains("tap-test-area"))
        #expect(try await AndroidE2E.helperPids().isEmpty)
    }

    @Test("helper and uiautomator trees carry the same ids", arguments: [
        ("tap-test", "tap-test-area"), ("switch-test", "swiftui-weather-alerts-switch"), ("slider-value-test", "slider-value-slider"),
    ])
    func sameIDsAsUiautomator(screen: String, marker: String) async throws {
        try await AndroidE2E.open(screen, waitingFor: marker)
        let helper = try await AndroidE2E.run("describe-ui")
        let uiautomator = try await AndroidE2E.run("describe-ui", environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])

        #expect(!uiautomator.stderr.contains("Warning:"), "a forced uiautomator read is silent: \(uiautomator.stderr)")
        let helperIDs = try AndroidE2E.ids(inDescribeUI: helper.stdout)
        #expect(helperIDs.contains(marker))
        #expect(helperIDs == (try AndroidE2E.ids(inDescribeUI: uiautomator.stdout)))
    }

    @Test("OFFSIDER_ANDROID_TREE=helper reads the slider's position as a percentage")
    func forcedHelperReadsSlider() async throws {
        try await AndroidE2E.open("slider-value-test", waitingFor: "slider-value-slider")
        let result = try await AndroidE2E.run("describe-ui", environment: ["OFFSIDER_ANDROID_TREE": "helper"])
        #expect(!result.stderr.contains("Warning:"), "stderr: \(result.stderr)")

        let tree = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let slider = try #require(AndroidE2E.nodes(in: tree).first { $0["id"] as? String == "slider-value-slider" })
        #expect(slider["value"] as? String == "25%")
    }

    @Test("the helper's dump draws a full page's Buy above the Products Tab beneath it")
    func drawingOrderOnStackedPage() async throws {
        try await AndroidE2E.open("stack-test", waitingFor: "stack-test-open-full")
        try await AndroidE2E.run("tap --id stack-test-open-full")
        _ = try await AndroidE2E.waitForNode { $0["id"] as? String == "stack-test-full-title-1" }

        let serial = try await AndroidE2E.serial()
        let raw = try await TestHelpers.runOffsiderAsPerson("describe-ui --raw-source --device \(serial)")
        let object = try #require(try JSONSerialization.jsonObject(with: try TestHelpers.jsonObject(in: raw.stdout)) as? [String: Any])
        let dump = try #require(object["source"] as? [String: Any])
        var orders: [String: Int] = [:]
        func visit(_ node: [String: Any]) {
            if let id = node["resourceId"] as? String, let order = node["drawingOrder"] as? Int { orders[id] = order }
            (node["children"] as? [[String: Any]] ?? []).forEach(visit)
        }
        for window in dump["windows"] as? [[String: Any]] ?? [] {
            if let root = window["root"] as? [String: Any] { visit(root) }
        }
        let buy = try #require(orders["stack-test-full-buy"], "\(orders)")
        let tab = try #require(orders["stack-test-tab-products"], "\(orders)")
        #expect(buy > tab)
        try await AndroidE2E.run("button back")
    }

    @Test("another UiAutomation client makes describe-ui fail as busy, without falling back")
    func busyWithAnotherClient() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()
        let before = try await AndroidE2E.accessibilityEnabled()

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: try AndroidE2E.adbPath())
        holder.arguments = ["-s", try await AndroidE2E.serial(), "shell", "uiautomator", "events"]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()

        var outcome: Result<SeparatedCommandOutput, any Error>
        do {
            let holding = try await AndroidE2E.eventually(timeout: 30) {
                let pid = try await AndroidE2E.shell("pidof uiautomator || true").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pid.isEmpty else { return false }
                return try await AndroidE2E.accessibilityEnabled() == "1"
            }
            guard holding else { throw AndroidE2EError(description: "uiautomator events never connected") }
            if before == "1" { try await Task.sleep(for: .seconds(2)) }
            outcome = .success(try await AndroidE2E.offsider("describe-ui"))
        } catch {
            outcome = .failure(error)
        }
        try await AndroidE2E.shell("for p in $(pidof uiautomator); do kill $p; done")
        if holder.isRunning { holder.terminate() }
        holder.waitUntilExit()

        let result = try outcome.get()
        #expect(result.exitCode == 8)
        #expect(result.stderr.contains("Another UiAutomation client is connected to"), "stderr: \(result.stderr)")
        #expect(!result.stderr.contains("Warning:"), "busy must not fall back to uiautomator: \(result.stderr)")
        #expect(result.stdout.contains(#""reason":"uiautomation_busy""#), "describe-ui reports the failure as its JSON envelope: \(result.stdout)")

        let freed = try await AndroidE2E.eventually(timeout: 20) {
            try await AndroidE2E.offsider("describe-ui").exitCode == 0
        }
        #expect(freed, "describe-ui still failed after the other client stopped")
    }

    @Test("with OFFSIDER_ANDROID_SESSION=off, Ctrl+C on a waiting tap stops its helper within 3 s")
    func interruptStopsHelper() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()

        let tap = Process()
        tap.executableURL = URL(fileURLWithPath: try TestHelpers.getOffsiderPath())
        tap.arguments = ["tap", "--id", "never-there", "--wait-timeout", "30", "--device", try await AndroidE2E.serial()]
        tap.environment = TestHelpers.childEnvironment().merging([Self.sessionVariable: "off"]) { _, new in new }
        tap.standardOutput = FileHandle.nullDevice
        tap.standardError = FileHandle.nullDevice
        try tap.run()

        let started = try await AndroidE2E.eventually(timeout: 25) {
            let pids = try await AndroidE2E.helperPids()
            return !pids.isEmpty
        }
        if !started { kill(tap.processIdentifier, SIGKILL) }
        try #require(started, "the waiting tap never started a helper")
        try await Task.sleep(for: .seconds(2))
        try #require(tap.isRunning, "the tap ended before it was interrupted")

        tap.interrupt()
        let interrupted = Date()
        var pids = ""
        let gone = try await AndroidE2E.eventually(timeout: 3, every: .milliseconds(100)) {
            pids = try await AndroidE2E.helperPids()
            return pids.isEmpty
        }
        print("helper gone \(Int(Date().timeIntervalSince(interrupted) * 1000)) ms after SIGINT")
        tap.waitUntilExit()

        #expect(tap.terminationReason == .uncaughtSignal)
        #expect(gone, "a helper was still running 3 s after SIGINT: \(pids)")
    }

    @Test("a push removes older helper copies and leaves the bundled one read-only for other users")
    func pushRemovesStaleCopies() async throws {
        let stale = "/data/local/tmp/offsider-helper-0000000000000000.dex"
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()
        try await AndroidE2E.shell("rm -f /data/local/tmp/offsider-helper-*.dex && touch \(stale)")

        let result = try await AndroidE2E.run("describe-ui")

        #expect(!result.stderr.contains("Warning:"), "stderr: \(result.stderr)")
        let copies = try await AndroidE2E.shell("ls /data/local/tmp/offsider-helper-*.dex").split(whereSeparator: \.isNewline).map(String.init)
        try #require(copies.count == 1 && copies != [stale], "copies after the push: \(copies)")
        let pushed = copies[0]
        let bundled = try Self.bundledDexSHA256()
        let onDevice = try await AndroidE2E.shell("sha256sum \(pushed)")
        #expect(onDevice.hasPrefix(bundled), "the device copy is \(onDevice), the bundle's dex \(bundled)")
        #expect(try await AndroidE2E.shell("stat -c %a \(pushed)").trimmingCharacters(in: .whitespacesAndNewlines) == "644")
    }

    @Test("a frozen app is reported as not responding within 12 s, its capture is refused, and the same helper reads on once the app runs again")
    func frozenAppIsBoundedAndRecovers() async throws {
        guard await AndroidE2E.shellCanBecomeRoot() else {
            print("skipped: this AVD's shell cannot become root to freeze the app")
            return
        }
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.run("describe-ui")
        let helper = try await AndroidE2E.helperPids()
        let app = try await AndroidE2E.pid(of: AndroidE2E.package)
        try #require(!helper.isEmpty && !app.isEmpty, "helper '\(helper)', app '\(app)'")
        let image = AndroidE2E.temporaryFile("frozen.png")
        defer { try? FileManager.default.removeItem(at: image) }

        try await AndroidE2E.shell("su 0 kill -STOP \(app)")
        let read: SeparatedCommandOutput
        let capture: SeparatedCommandOutput
        let readSeconds: TimeInterval
        do {
            let started = Date()
            read = try await AndroidE2E.offsider("describe-ui")
            readSeconds = Date().timeIntervalSince(started)
            capture = try await AndroidE2E.offsider("screenshot --output \(image.path)", environment: ["OFFSIDER_RUN": "off"])
        } catch {
            try await AndroidE2E.shell("su 0 kill -CONT \(app)")
            throw error
        }
        try await AndroidE2E.shell("su 0 kill -CONT \(app)")
        try await AndroidE2E.dismissANRDialog()

        #expect(read.exitCode != 0)
        #expect(read.stderr.contains("the app is not responding or still starting"), "stderr: \(read.stderr)")
        #expect(readSeconds < 12, "the read took \(readSeconds) s")
        #expect(capture.exitCode != 0, "stderr: \(capture.stderr)")
        #expect(!FileManager.default.fileExists(atPath: image.path))
        let recovered = try await AndroidE2E.eventually(timeout: 15) { try await AndroidE2E.offsider("describe-ui").exitCode == 0 }
        #expect(recovered, "no read succeeded within 15 s of the app running again")
        #expect(try await AndroidE2E.helperPids() == helper)
    }

    @Test("after Android's framework restarts, the next reads replace the warm helper by themselves, with no session stop", .enabled(if: isAndroidBootE2EEnabled))
    func frameworkRestartIsRecovered() async throws {
        guard await AndroidE2E.shellCanBecomeRoot() else {
            print("skipped: this AVD's shell cannot become root to restart the framework")
            return
        }
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.run("describe-ui")
        let helper = try await AndroidE2E.helperPids()
        let server = try await AndroidE2E.pid(of: "system_server")
        try #require(!helper.isEmpty && !server.isEmpty, "helper '\(helper)', system_server '\(server)'")

        try await AndroidE2E.shell("su 0 kill \(server)")
        let restarted = try await AndroidE2E.eventually(timeout: 180, every: .seconds(1)) {
            let now = try await AndroidE2E.pid(of: "system_server")
            guard !now.isEmpty, now != server else { return false }
            let state = try await AndroidE2E.shell("getprop init.svc.bootanim; service check accessibility; dumpsys window 2>/dev/null | grep mCurrentFocus || true")
            return state.contains("stopped") && state.contains("accessibility: found") && state.contains("mCurrentFocus=Window{")
        }
        try #require(restarted, "Android's framework was not back within 180 s")

        var failures: [String] = []
        let read = try await AndroidE2E.eventually(timeout: 60, every: .seconds(1)) {
            let result = try await AndroidE2E.offsider("describe-ui")
            // The launcher may not have drawn yet, which is a read of the device as it is; a read the helper failed is the bug.
            if result.exitCode != 0, result.stdout.contains(#""reason":"helper_failed""#) { failures.append(result.stderr) }
            return result.exitCode == 0
        }
        #expect(read, "no read succeeded within 60 s of the restart")
        #expect(failures.isEmpty, "reads failed on the helper: \(failures)")
        let fresh = try await AndroidE2E.helperPids()
        #expect(!fresh.isEmpty && fresh != helper, "helper before '\(helper)', after '\(fresh)'")
        try await AndroidE2E.dismissANRDialog()
    }
}
