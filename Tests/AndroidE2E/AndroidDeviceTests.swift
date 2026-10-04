import Foundation
import ImageIO
import Testing

@Suite("Android list-devices", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidListDevicesTests {
    @Test("the guarded emulator is listed as booted with its AVD name and Android version")
    func guardedRow() async throws {
        let serial = try await AndroidE2E.serial()
        let result = try await TestHelpers.runOffsiderCommandSeparated("list-devices --platform android")
        #expect(result.exitCode == 0)
        let row = result.stdout.split(separator: "\n").first { $0.contains(" \(serial) ") }
        #expect(row?.contains("Booted") == true)
        #expect(row?.contains(AndroidE2E.expectedAVD) == true)
        #expect(row?.contains("Android") == true)
    }

    @Test("--json rows carry the neutral keys")
    func jsonKeys() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("list-devices --platform android --json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let rows = try #require(object["devices"] as? [[String: Any]])
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(Set(row.keys) == ["id", "platform", "state", "name", "osVersion", "deviceType", "kind", "connection"])
            #expect(row["platform"] as? String == "android")
        }
    }

    @Test("an AVD name routes to the running serial")
    func avdNameRoutes() async throws {
        let serial = try await AndroidE2E.serial()
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let result = try await TestHelpers.runOffsiderCommandSeparated("describe-ui --device \(AndroidE2E.expectedAVD)", timeout: 90)
        #expect(result.exitCode == 0)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["device"] as? String == serial)
    }
}

@Suite("Android describe-ui", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidDescribeUITests {
    @Test("the envelope names the platform and device, with dp frames and testID ids")
    func envelope() async throws {
        let serial = try await AndroidE2E.serial()
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let tree = try await AndroidE2E.tree()

        #expect(tree["platform"] as? String == "android")
        #expect(tree["device"] as? String == serial)
        let screen = try #require(tree["screen"] as? [String: Any])
        #expect(screen["orientation"] as? String == "portrait")
        #expect((screen["scale"] as? Double ?? 0) > 1)
        let nodes = AndroidE2E.nodes(in: tree)
        #expect(nodes.first?["role"] as? String == "application")
        let back = try #require(nodes.first { $0["id"] as? String == "BackButton" })
        let frame = try #require(back["frame"] as? [String: Double])
        #expect(abs((frame["width"] ?? 0) - 44) < 1, "BackButton is 44 dp wide, got \(frame)")
        #expect(nodes.contains { $0["id"] as? String == "tap-test-area" })
        #expect(nodes.contains { $0["id"] as? String == "tap-count" })
    }

    @Test("--point returns the deepest node there as the only root")
    func point() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let centre = try await AndroidE2E.centre(of: "BackButton")
        let result = try await AndroidE2E.run("describe-ui --point \(centre.x),\(centre.y)")
        let tree = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let roots = try #require(tree["roots"] as? [[String: Any]])
        #expect(roots.count == 1)
        #expect(roots.first?["id"] as? String == "BackButton")
    }
}

@Suite("Android screenshot", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidScreenshotE2ETests {
    @Test("the PNG is the display's logical pixel size")
    func size() async throws {
        let output = AndroidE2E.temporaryFile("shot.png")
        defer { try? FileManager.default.removeItem(at: output) }
        try await AndroidE2E.run("screenshot --output \(AndroidE2E.quote(output.path))")

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let expected = try await AndroidE2E.logicalPixelSize()
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == expected.width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == expected.height)
    }
}
