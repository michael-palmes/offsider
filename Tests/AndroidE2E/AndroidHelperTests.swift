import Darwin
import Foundation
import Testing

extension AndroidE2E {
    /// Pids of Offsider helpers running on the device; empty when there are none.
    static func helperPids() async throws -> String {
        try await shell("pidof offsider-helper || true").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func accessibilityEnabled() async throws -> String {
        try await shell("settings get secure accessibility_enabled").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits for earlier commands' helpers to exit, so a test starts with the UiAutomation slot free.
    static func waitForNoHelper(timeout: TimeInterval = 15) async throws {
        guard try await eventually(timeout: timeout, { try await helperPids().isEmpty }) else {
            throw AndroidE2EError(description: "an Offsider helper was still running after \(Int(timeout)) s: \(try await helperPids())")
        }
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

    @Test("a command leaves no helper running and puts accessibility_enabled back")
    func cleansUp() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()
        let before = try await AndroidE2E.accessibilityEnabled()

        try await AndroidE2E.run("describe-ui")

        var pids = ""
        var after = ""
        let clean = try await AndroidE2E.eventually(timeout: 3) {
            pids = try await AndroidE2E.helperPids()
            after = try await AndroidE2E.accessibilityEnabled()
            return pids.isEmpty && after == before
        }
        #expect(clean, "helper pids '\(pids)', accessibility_enabled \(after) (was \(before))")
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
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Another UiAutomation client is connected to"), "stderr: \(result.stderr)")
        #expect(!result.stderr.contains("Warning:"), "busy must not fall back to uiautomator: \(result.stderr)")
        #expect(result.stdout.isEmpty)

        let freed = try await AndroidE2E.eventually(timeout: 20) {
            try await AndroidE2E.offsider("describe-ui").exitCode == 0
        }
        #expect(freed, "describe-ui still failed after the other client stopped")
    }

    @Test("Ctrl+C on a waiting tap stops its helper within 3 s")
    func interruptStopsHelper() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.waitForNoHelper()

        let tap = Process()
        tap.executableURL = URL(fileURLWithPath: try TestHelpers.getOffsiderPath())
        tap.arguments = ["tap", "--id", "never-there", "--wait-timeout", "30", "--device", try await AndroidE2E.serial()]
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
}
