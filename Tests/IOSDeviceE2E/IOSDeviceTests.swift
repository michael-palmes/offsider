import Foundation
import Testing

@Suite("iOS device list", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceListE2ETests {
    @Test("list-devices shows the device as a physical USB row with the usual JSON keys")
    func listed() async throws {
        let udid = try await IOSDeviceE2E.udid()
        let result = try await TestHelpers.runOffsiderCommandSeparated("list-devices --platform ios --json", timeout: 120)
        #expect(result.exitCode == 0, "\(result.stderr)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let rows = try #require(object["devices"] as? [[String: Any]])
        let row = try #require(rows.first { $0["id"] as? String == udid }, "list-devices has no row for \(udid)")
        #expect(row["platform"] as? String == "ios")
        #expect(row["kind"] as? String == "physical")
        #expect(row["connection"] as? String == "usb")
        let readiness = ["Booted", "Untrusted", "Developer Mode off", "Preparing", "Reconnecting"]
        #expect(readiness.contains(row["state"] as? String ?? ""), "state was \(row["state"] ?? "missing")")
        #expect(Set(row.keys).isSuperset(of: ["id", "platform", "state", "name", "osVersion", "deviceType", "kind", "connection"]))
        #expect((row["name"] as? String)?.isEmpty == false)
    }
}

@Suite("iOS device doctor", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceDoctorE2ETests {
    static let checkIDs = [
        "ios-device.xcode", "ios-device.coredevice", "ios-device.listed", "ios-device.transport", "ios-device.pairing",
        "ios-device.developer-mode", "ios-device.ddi", "ios-device.tunnel", "ios-device.lock-state", "ios-device.hid",
        "ios-device.ui-automation", "ios-device.session", "ios-device.usbmuxd", "ios-device.runner-signing",
    ]

    @Test("doctor --json reports the ios-device checks and exits 0 or 3; a dark screen may fail only the HID check")
    func doctor() async throws {
        let result = try await IOSDeviceE2E.offsider("doctor --json", timeout: 180)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], "doctor printed no JSON: \(result.stderr)")
        let checks = try #require(object["checks"] as? [[String: Any]])
        let status = Dictionary(uniqueKeysWithValues: checks.compactMap { check in (check["id"] as? String).map { ($0, check["status"] as? String ?? "") } })
        for id in Self.checkIDs {
            #expect(status[id] != nil, "doctor has no \(id) check")
        }
        #expect(status["ios-device.listed"] == "pass")
        #expect(status["ios-device.transport"] == "pass")
        #expect(status["ios-device.runner-signing"] == "pass", "OFFSIDER_IOS_TEAM_ID should settle the runner's team")
        let failed = status.filter { $0.value == "fail" }.map(\.key)
        if result.exitCode == 4, status["ios-device.lock-state"] == "warn", failed == ["ios-device.hid"] {
            FileHandle.standardError.write(Data("note: doctor failed only ios-device.hid while the screen is off\n".utf8))
            return
        }
        #expect([0, 3].contains(result.exitCode), "doctor exited \(result.exitCode) with failures \(failed)")
    }
}

@Suite("iOS device screenshot", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceScreenshotE2ETests {
    /// devicectl turns clockwise in quarter turns named `rot0` to `rot270`.
    static func degrees(_ name: Any?) -> Int {
        (name as? String).flatMap { Int($0.dropFirst(3)) } ?? 0
    }

    @Test("a screenshot through the broker is its stream's frame, in the display's current orientation and shape")
    func size() async throws {
        try await IOSDeviceE2E.requireAwake()
        let displays = try #require(IOSDeviceE2EGuard.result(try await IOSDeviceE2E.info("displays"))?["displays"] as? [[String: Any]])
        let display = try #require(displays.first { $0["primary"] as? Bool == true } ?? displays.first)
        let landscape = (Self.degrees(display["nativeOrientation"]) + Self.degrees(display["currentOrientation"])) % 180 == 90
        func oriented(_ pair: [Int]) -> [Int] {
            let (long, short) = (max(pair[0], pair[1]), min(pair[0], pair[1]))
            return landscape ? [long, short] : [short, long]
        }
        var expected: [[Int]] = []
        if let native = display["nativeSize"] as? [Int], native.count == 2 { expected.append(oriented(native)) }
        if let bounds = display["bounds"] as? [[Int]], bounds.count == 2, bounds[1].count == 2 { expected.append(oriented(bounds[1])) }
        try #require(!expected.isEmpty, "info displays reported no size")

        let file = try await IOSDeviceE2E.screenshot("plain.png")
        defer { try? FileManager.default.removeItem(at: file) }
        let png = try IOSDeviceE2E.pngSize(at: file)
        let broker = try #require(try await IOSDeviceE2E.sessions().broker, "screenshot started no session broker")
        let stream = try #require(broker["stream"] as? [String: Any], "the broker reports no stream: \(broker)")
        #expect(stream["state"] as? String == "live", "the broker's stream is not live: \(stream)")
        if let width = stream["width"] as? Int, let height = stream["height"] as? Int {
            expected.append(oriented([width, height]))
        }
        #expect(expected.contains([png.width, png.height]), "the PNG is \(png.width) x \(png.height); devicectl and the stream report \(expected)")
        let shape = Double(expected[0][0]) / Double(expected[0][1])
        #expect(abs(Double(png.width) / Double(png.height) - shape) < 0.01, "the PNG's shape differs from the display's")
    }

    @Test("--mask-secure answers with a PNG or a clean error, never a crash")
    func maskSecure() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-ios-device-e2e-\(UUID().uuidString)-masked.png")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await IOSDeviceE2E.offsider("screenshot --mask-secure --output \(IOSDeviceE2E.quote(output.path))", timeout: 600)
        #expect(result.exitCode < 128, "screenshot --mask-secure died with \(result.exitCode): \(result.stderr)")
        if result.exitCode == 0 {
            _ = try IOSDeviceE2E.pngSize(at: output)
        } else {
            #expect(result.stderr.contains("Error:"), "a failed --mask-secure printed no error: \(result.stderr)")
            FileHandle.standardError.write(Data("note: screenshot --mask-secure exited \(result.exitCode): \(result.stderr.prefix(300))\n".utf8))
        }
    }
}

@Suite("iOS device settings", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceSettingsE2ETests {
    static func json(_ arguments: String) async throws -> [String: Any] {
        let result = try await IOSDeviceE2E.run("\(arguments) --json", timeout: 120)
        return try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    }

    @Test("appearance reads, sets the other style and is put back")
    func appearance() async throws {
        let original = try #require(try await Self.json("appearance")["appearance"] as? String)
        let other = original == "dark" ? "light" : "dark"
        do {
            let set = try await Self.json("appearance \(other)")
            #expect(set["previous"] as? String == original)
            #expect(try await Self.json("appearance")["appearance"] as? String == other)
        } catch {
            _ = try? await IOSDeviceE2E.run("appearance \(original)")
            throw error
        }
        try await IOSDeviceE2E.run("appearance \(original)")
        #expect(try await Self.json("appearance")["appearance"] as? String == original)
    }

    static let sizes = [
        "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
    ]

    @Test("content-size reads, moves one step and is put back")
    func contentSize() async throws {
        let original = try #require(try await Self.json("content-size")["contentSize"] as? String)
        let index = Self.sizes.firstIndex(of: original) ?? Self.sizes.firstIndex(of: "large")!
        let step = Self.sizes[index == Self.sizes.count - 1 ? index - 1 : index + 1]
        do {
            try await IOSDeviceE2E.run("content-size \(step)")
            #expect(try await Self.json("content-size")["contentSize"] as? String == step)
        } catch {
            _ = try? await IOSDeviceE2E.run("content-size \(original)")
            throw error
        }
        try await IOSDeviceE2E.run("content-size \(original)")
        #expect(try await Self.json("content-size")["contentSize"] as? String == original)
    }
}

@Suite("iOS device input", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceInputE2ETests {
    static let app = "--app \(IOSDeviceE2E.playgroundBundleID)"

    /// Taps at `point` and returns where the playground's tap area says it landed, in its own coordinates.
    static func tap(_ point: (x: Int, y: Int), expectingCount count: Int) async throws -> (x: Int, y: Int) {
        try await IOSDeviceE2E.run("tap -x \(point.x) -y \(point.y) --verify \(app)")
        _ = try await IOSDeviceE2E.node(labelled: "Tap Count: \(count)")
        let location = try await IOSDeviceE2E.waitForNode { ($0["label"] as? String)?.hasPrefix("Tap Location:") == true }
        let label = try #require(location["label"] as? String)
        return try #require(IOSDeviceE2E.coordinates(in: label), "unreadable \(label)")
    }

    @Test("taps at two points land the same distance apart on the playground, across the whole screen, through the broker")
    func tapAtPoints() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingForLabel: "Tap Count: 0")
        let screen = try await IOSDeviceE2E.screen()
        let first = (x: Int(screen.width * 0.2), y: Int(screen.height * 0.5))
        let second = (x: Int(screen.width * 0.8), y: Int(screen.height * 0.85))
        let landedFirst = try await Self.tap(first, expectingCount: 1)
        let landedSecond = try await Self.tap(second, expectingCount: 2)
        let sent = (x: second.x - first.x, y: second.y - first.y)
        let measured = (x: landedSecond.x - landedFirst.x, y: landedSecond.y - landedFirst.y)
        #expect(abs(measured.x - sent.x) <= 3 && abs(measured.y - sent.y) <= 3,
                "taps \(sent) points apart landed \(measured) apart (at \(landedFirst) and \(landedSecond))")
        #expect(abs(landedFirst.x - first.x) <= 3, "a tap at x \(first.x) landed at x \(landedFirst.x)")
        try await IOSDeviceE2E.requireBrokerInput()
    }

    @Test("tap --label --verify on a static text exits 5, in any orientation")
    func tapNoOp() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("swipe-test", waitingForLabel: "Swipe Playground")
        let result = try await IOSDeviceE2E.offsider("tap --label 'Swipe Playground' --verify \(Self.app)")
        #expect(result.exitCode == 5, "tap on a static text exited \(result.exitCode): \(result.stderr)")
    }

    @Test("swipe through the broker draws one path that ends where it was sent")
    func swipe() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("swipe-test", waitingForLabel: "Count: 0")
        let area = try await IOSDeviceE2E.waitForNode { $0["role"] as? String == "other" && $0["id"] as? String == "swipe-test-screen" }
        let start = try IOSDeviceE2E.point(in: area, x: 0.3, y: 0.5)
        let end = try IOSDeviceE2E.point(in: area, x: 0.7, y: 0.5)
        try await IOSDeviceE2E.run("swipe --start-x \(start.x) --start-y \(start.y) --end-x \(end.x) --end-y \(end.y) --duration 0.5")
        _ = try await IOSDeviceE2E.node(labelled: "Count: 1")
        let ended = try await IOSDeviceE2E.waitForNode { ($0["label"] as? String)?.hasPrefix("End: (") == true }
        let label = try #require(ended["label"] as? String)
        let landed = try #require(IOSDeviceE2E.coordinates(in: label), "unreadable \(label)")
        #expect(abs(landed.x - end.x) <= 20 && abs(landed.y - end.y) <= 20, "the swipe ended at \(label), not near \(end)")
        try await IOSDeviceE2E.requireBrokerInput()
    }

    @Test("ASCII type reaches the focused field through the broker's keyboard")
    func typeASCII() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("text-input", waitingForLabel: "Text Input Playground")
        let field = try await IOSDeviceE2E.waitForNode { $0["role"] as? String == "textField" }
        let centre = try IOSDeviceE2E.point(in: field)
        try await IOSDeviceE2E.run("tap -x \(centre.x) -y \(centre.y) \(Self.app)")
        try await IOSDeviceE2E.run("type hello")
        _ = try await IOSDeviceE2E.waitForNode { $0["role"] as? String == "textField" && $0["value"] as? String == "hello" }
        try await IOSDeviceE2E.requireBrokerInput()
    }

    @Test("type --into-id sees the runner's keyboard focus, which describe-ui shows and --require-focus-id accepts")
    func typeIntoField() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("text-input", waitingForLabel: "Text Input Playground")
        try await IOSDeviceE2E.run("type --into-id text-input-field hello \(Self.app)")
        let field = try await IOSDeviceE2E.waitForNode { $0["id"] as? String == "text-input-field" && $0["value"] as? String == "hello" }
        #expect((field["state"] as? [String: Any])?["focused"] as? Bool == true, "describe-ui did not show the field focused")
        try await IOSDeviceE2E.run("type --require-focus-id text-input-field world \(Self.app)")
        _ = try await IOSDeviceE2E.waitForNode { $0["id"] as? String == "text-input-field" && $0["value"] as? String == "helloworld" }
    }

    @Test("button home leaves the app through the broker, and a relaunch brings it back")
    func home() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingForLabel: "Tap Count: 0")
        try await IOSDeviceE2E.run("button home")
        let deadline = Date().addingTimeInterval(20)
        var left = false
        while !left, Date() < deadline {
            let read = try await IOSDeviceE2E.offsider("describe-ui \(Self.app)")
            left = read.exitCode != 0 || !read.stdout.contains("Tap Count: 0")
            if !left { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(left, "the playground still showed its tap screen after button home")
        try await IOSDeviceE2E.requireBrokerInput()
        try await IOSDeviceE2E.open("tap-test", waitingForLabel: "Tap Count: 0")
    }
}

@Suite("iOS device tree", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceTreeE2ETests {
    static let app = "--app \(IOSDeviceE2E.playgroundBundleID)"

    @Test("describe-ui --app --summary lists the playground's elements on a full-size screen")
    func summary() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingForLabel: "Tap Count: 0")
        let result = try await IOSDeviceE2E.run("describe-ui \(Self.app) --summary")
        #expect(result.stdout.contains("Detects taps sent by CLI commands"))
        #expect(result.stdout.contains("Tap Count: 0"))
        let tree = try DescribeUITree.parse(try await IOSDeviceE2E.run("describe-ui \(Self.app)").stdout)
        let screen = try #require(tree["screen"] as? [String: Any])
        let root = try #require(DescribeUITree.nodes(in: tree).first { $0["role"] as? String == "application" })
        let frame = try IOSDeviceE2E.frame(of: root)
        #expect(screen["width"] as? Double == frame.width && screen["height"] as? Double == frame.height,
                "a full-screen app's frame \(frame) differs from the screen \(screen)")
    }

    @Test("wait --label finds a present element and times out on a missing one")
    func wait() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingForLabel: "Tap Count: 0")
        try await IOSDeviceE2E.run("wait --label 'Tap Count: 0' --timeout 20 \(Self.app)")
        let missing = try await IOSDeviceE2E.offsider("wait --id offsider-no-such-element --timeout 3 \(Self.app)")
        #expect(missing.exitCode == 5, "wait for a missing element exited \(missing.exitCode): \(missing.stderr)")
    }

    /// The text-input screen's field reports "empty" as its value, which the runner cannot tell from text, so this uses the search field.
    @Test("Unicode type --replace sets the field through the runner, and assert --has-value sees it")
    func replaceAndAssert() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("searchable-test", waitingForLabel: "Search Query: empty")
        let field = try await IOSDeviceE2E.waitForNode { $0["role"] as? String == "searchField" }
        let centre = try IOSDeviceE2E.point(in: field)
        try await IOSDeviceE2E.run("tap -x \(centre.x) -y \(centre.y) \(Self.app)")
        let text = "héllo ✓ 你好"
        try await IOSDeviceE2E.run("type --replace \(IOSDeviceE2E.quote(text))")
        _ = try await IOSDeviceE2E.waitForNode { $0["role"] as? String == "searchField" && $0["value"] as? String == text }
        try await IOSDeviceE2E.run("assert --label 'Search Books' --element-type searchField --has-value \(IOSDeviceE2E.quote(text)) \(Self.app)")
        let wrong = try await IOSDeviceE2E.offsider("assert --label 'Search Books' --element-type searchField --has-value hello \(Self.app)")
        #expect(wrong.exitCode != 0, "assert --has-value accepted a value the field does not hold")
    }
}

@Suite("iOS device runner", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceRunnerE2ETests {
    static func sessions() async throws -> [[String: Any]] {
        let result = try await IOSDeviceE2E.run("runner status --json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        return try #require(object["sessions"] as? [[String: Any]])
    }

    static func running() async throws -> Bool {
        let udid = try await IOSDeviceE2E.udid()
        return try await sessions().contains { $0["device"] as? String == udid && $0["running"] as? Bool == true }
    }

    static func bothRunning() async throws -> (runner: Bool, broker: Bool) {
        let row = try await IOSDeviceE2E.sessions()
        return (row.runner?["running"] as? Bool == true, row.broker?["running"] as? Bool == true && row.broker?["answering"] as? Bool == true)
    }

    @Test("session status shows the runner and the broker, session stop ends both, and the next commands start them again")
    func sessionLifecycle() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        let udid = try await IOSDeviceE2E.udid()
        try await IOSDeviceE2E.run("describe-ui")
        let file = try await IOSDeviceE2E.screenshot("session.png")
        try? FileManager.default.removeItem(at: file)
        let started = try await Self.bothRunning()
        #expect(started.runner, "no running runner after describe-ui")
        #expect(started.broker, "no answering broker after screenshot")

        let stop = try await IOSDeviceE2E.run("session stop --json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(stop.stdout.utf8)) as? [String: Any])
        let entry = try #require((object["stopped"] as? [[String: Any]])?.first { $0["device"] as? String == udid }, "session stop listed nothing for \(udid)")
        #expect(entry["runner"] as? Bool == true)
        #expect(entry["broker"] as? Bool == true)
        let stopped = try await Self.bothRunning()
        #expect(!stopped.runner && !stopped.broker, "a session still runs after session stop")

        try await IOSDeviceE2E.run("describe-ui")
        let again = try await IOSDeviceE2E.screenshot("session-again.png")
        try? FileManager.default.removeItem(at: again)
        let restarted = try await Self.bothRunning()
        #expect(restarted.runner && restarted.broker, "describe-ui and screenshot after session stop did not start both again")
    }

    @Test("runner status shows the session after a tree read, stop ends it, and the next read starts it again")
    func lifecycle() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        let udid = try await IOSDeviceE2E.udid()
        try await IOSDeviceE2E.run("describe-ui")
        #expect(try await Self.running(), "no running runner session after describe-ui")

        let stop = try await IOSDeviceE2E.run("runner stop --json")
        let stopped = try #require(try JSONSerialization.jsonObject(with: Data(stop.stdout.utf8)) as? [String: Any])
        #expect((stopped["stopped"] as? [String])?.contains(udid) == true)
        #expect(try await !Self.running(), "the runner still reads as running after runner stop")

        try await IOSDeviceE2E.run("describe-ui")
        #expect(try await Self.running(), "describe-ui after runner stop did not start a new session")
    }
}
