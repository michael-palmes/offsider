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
        "ios-device.ui-automation", "ios-device.usbmuxd", "ios-device.runner-signing",
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

    @Test("a screenshot is a PNG the size of the display in its current orientation")
    func size() async throws {
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
        #expect(expected.contains([png.width, png.height]), "the PNG is \(png.width) x \(png.height); devicectl reports \(expected) for this orientation")
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
    @Test("tap --id --verify lands on the element")
    func tapByID() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingFor: "tap-test-area")
        try await IOSDeviceE2E.run("tap --id tap-test-area --verify --app \(IOSDeviceE2E.playgroundBundleID)")
        _ = try await IOSDeviceE2E.waitForLabel(of: "tap-count") { $0 == "Tap Count: 1" }
    }

    @Test("tap --verify on an element that does nothing exits 5")
    func tapNoOp() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingFor: "tap-test-title")
        let result = try await IOSDeviceE2E.offsider("tap --id tap-test-title --verify --app \(IOSDeviceE2E.playgroundBundleID)")
        #expect(result.exitCode == 5, "tap on a static title exited \(result.exitCode): \(result.stderr)")
    }

    @Test("ASCII type reaches the focused field through the keyboard")
    func typeASCII() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("text-input", waitingFor: "text-input-field")
        try await IOSDeviceE2E.run("tap --id text-input-field --app \(IOSDeviceE2E.playgroundBundleID)")
        try await IOSDeviceE2E.run("type hello")
        _ = try await IOSDeviceE2E.waitForNode { $0["id"] as? String == "text-input-field" && $0["value"] as? String == "hello" }
    }

    @Test("button home leaves the app, and a relaunch brings it back")
    func home() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingFor: "tap-test-area")
        try await IOSDeviceE2E.run("button home")
        let deadline = Date().addingTimeInterval(20)
        var left = false
        while !left, Date() < deadline {
            let read = try await IOSDeviceE2E.offsider("describe-ui --app \(IOSDeviceE2E.playgroundBundleID)")
            left = read.exitCode != 0 || !read.stdout.contains("\"tap-test-area\"")
            if !left { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(left, "the playground still showed tap-test-area after button home")
        try await IOSDeviceE2E.open("tap-test", waitingFor: "tap-test-area")
    }
}

@Suite("iOS device tree", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceTreeE2ETests {
    @Test("describe-ui --app --summary lists the playground's elements")
    func summary() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingFor: "tap-test-area")
        let result = try await IOSDeviceE2E.run("describe-ui --app \(IOSDeviceE2E.playgroundBundleID) --summary")
        #expect(result.stdout.contains("tap-test-title"))
        #expect(result.stdout.contains("tap-count"))
    }

    @Test("wait --id finds a present element and times out on a missing one")
    func wait() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("tap-test", waitingFor: "tap-test-area")
        try await IOSDeviceE2E.run("wait --id tap-count --timeout 20 --app \(IOSDeviceE2E.playgroundBundleID)")
        let missing = try await IOSDeviceE2E.offsider("wait --id offsider-no-such-element --timeout 3 --app \(IOSDeviceE2E.playgroundBundleID)")
        #expect(missing.exitCode == 5, "wait for a missing element exited \(missing.exitCode): \(missing.stderr)")
    }

    @Test("Unicode type --replace sets the field, and assert --has-value sees it")
    func replaceAndAssert() async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.open("text-input", waitingFor: "text-input-field")
        try await IOSDeviceE2E.run("tap --id text-input-field --app \(IOSDeviceE2E.playgroundBundleID)")
        let text = "héllo ✓ 你好"
        try await IOSDeviceE2E.run("type --replace \(IOSDeviceE2E.quote(text))")
        _ = try await IOSDeviceE2E.waitForNode { $0["id"] as? String == "text-input-field" && $0["value"] as? String == text }
        try await IOSDeviceE2E.run("assert --id text-input-field --has-value \(IOSDeviceE2E.quote(text)) --app \(IOSDeviceE2E.playgroundBundleID)")
        let wrong = try await IOSDeviceE2E.offsider("assert --id text-input-field --has-value hello --app \(IOSDeviceE2E.playgroundBundleID)")
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
