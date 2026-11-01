import Foundation
import OffsiderCore
import Testing

/// The one mask rule on a real screen: a password a toggle revealed, text nested in what `offsider.mask.json` names, and what video refuses or warns about.
@Suite("React Native mask rule", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeMaskRuleTests {
    static let password = "4821-fixture"
    static let amount = "7730.25"
    static let holder = "Holder 5519"

    private static func device(_ platform: RNPlatform) async throws -> String {
        platform == .android ? try await AndroidE2E.serial() : try IOSRNPlayground.udid()
    }

    /// Runs offsider in `directory`, where it finds `offsider.mask.json`.
    private static func runIn(_ directory: URL, _ arguments: String, platform: RNPlatform, environment: [String: String]? = nil, timeout: TimeInterval = 60) async throws -> SeparatedCommandOutput {
        if platform == .android { try await AndroidE2E.dismissANRDialog() }
        let binary = try TestHelpers.getOffsiderPath()
        let device = try await device(platform)
        return try await CommandRunner.runSeparated("cd \(AndroidE2E.quote(directory.path)) && \(binary) \(arguments) --device \(device)", environment: environment, timeout: timeout)
    }

    private static func recordVideo(to output: String, in directory: URL, platform: RNPlatform, environment: [String: String]? = nil) async throws -> SeparatedCommandOutput {
        try await runIn(directory, "record-video --duration 3 --output \(AndroidE2E.quote(output))", platform: platform, environment: environment)
    }

    /// Every file of the per-device tree cache, as a command leaves it on disk.
    private static func expectTreeCacheHolds(none secrets: [String]) throws {
        let folder = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.treesDirectoryName)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder)
        #expect(!files.isEmpty, "no tree was cached, so this proves nothing")
        for file in files {
            let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(file)), as: UTF8.self)
            for secret in secrets {
                #expect(!text.contains(secret), "\(file) holds what was masked")
            }
        }
    }

    private static func isBlack(at frame: (x: Double, y: Double, width: Double, height: Double), in path: String) throws -> Bool {
        try ReactNativeEvidenceTests.pixel(atPoint: (frame.x + frame.width / 2, frame.y + frame.height / 2), in: path) == [0, 0, 0]
    }

    @Test("a password a toggle revealed stays hidden in trees and messages, is painted, and stops video", arguments: RNPlatform.enabled)
    func revealedPassword(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("mask-rule-test")
        try await app.run("tap --id mask-rule-test-reveal")
        _ = try await app.waitForNode { $0["label"] as? String == "Hide Password" }

        let summary = try await app.run("describe-ui --summary").stdout
        #expect(summary.contains("revealed password field"), "\(summary)")
        #expect(try await !app.run("describe-ui").stdout.contains(Self.password))

        let miss = try await app.offsider("assert --id mask-rule-test-password --has-value nope")
        #expect(miss.exitCode != 0)
        #expect(miss.stderr.contains("has a masked value"), "\(miss.stderr)")
        #expect(!(miss.stdout + miss.stderr).contains(Self.password))
        try Self.expectTreeCacheHolds(none: [Self.password])

        try await ReactNativeEnvironmentTests.withTemporaryDirectory { directory in
            let shot = directory.appendingPathComponent("revealed.png").path
            let json = try await app.run("screenshot --scale points --json --output \(AndroidE2E.quote(shot))").stdout
            let report = try JSONDecoder().decode(ReactNativeEvidenceTests.Shot.self, from: Data(json.utf8))
            #expect(report.maskedBy?["secure"] == 1, "\(json)")
            #expect(try Self.isBlack(at: try await app.frame(of: "mask-rule-test-password"), in: shot), "the revealed password was left unmasked")

            let video = directory.appendingPathComponent("revealed.mp4").path
            let recording = try await Self.recordVideo(to: video, in: directory, platform: platform)
            #expect(recording.exitCode == 1, "\(recording.stderr)")
            #expect(recording.stderr.contains("will not start while a password field is on screen"), "\(recording.stderr)")
            #expect(!FileManager.default.fileExists(atPath: video), "a refused recording wrote a file")
        }
    }

    @Test("with the tree cache off, a password a toggle revealed still stays hidden in trees, is painted, and stops video", arguments: RNPlatform.enabled)
    func revealedPasswordWithCacheOff(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("mask-rule-test")
        let off = ["OFFSIDER_TREE_CACHE": "off"]
        let folder = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.treesDirectoryName)
        let device = try await Self.device(platform)
        let name = SecureFieldRecord.fileName(platform: platform == .android ? .android : .ios, device: device)
        OffsiderPrivateDirectory.removeFile(named: name, in: folder)

        try await app.run("tap --id mask-rule-test-reveal", environment: off)
        #expect(FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name)), "with the cache off, the tap remembered no password field")
        try await app.run("wait --label 'Hide Password' --timeout 10", environment: off)

        let summary = try await app.run("describe-ui --summary", environment: off).stdout
        #expect(summary.contains("revealed password field"), "\(summary)")
        #expect(try await !app.run("describe-ui", environment: off).stdout.contains(Self.password))

        try await ReactNativeEnvironmentTests.withTemporaryDirectory { directory in
            let shot = directory.appendingPathComponent("revealed.png").path
            let json = try await app.run("screenshot --scale points --json --output \(AndroidE2E.quote(shot))", environment: off).stdout
            let report = try JSONDecoder().decode(ReactNativeEvidenceTests.Shot.self, from: Data(json.utf8))
            #expect(report.maskedBy?["secure"] == 1, "\(json)")

            let video = directory.appendingPathComponent("revealed.mp4").path
            let recording = try await Self.recordVideo(to: video, in: directory, platform: platform, environment: off)
            #expect(recording.exitCode == 1, "\(recording.stderr)")
            #expect(recording.stderr.contains("will not start while a password field is on screen"), "\(recording.stderr)")
            #expect(!FileManager.default.fileExists(atPath: video), "a refused recording wrote a file")
            #expect(try Self.isBlack(at: try await app.frame(of: "mask-rule-test-password"), in: shot), "the revealed password was left unmasked")
        }
    }

    @Test("on Android a mask file's match hides what is nested in it and its text in a parent's label", arguments: RNPlatform.enabled.filter { $0 == .android })
    func nestedRule(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("mask-rule-test")
        let tree = try await app.run("describe-ui --summary").stdout
        #expect(tree.contains("Balance \(Self.amount) Details") && tree.contains(Self.holder), "the fixture no longer shows what this test hides: \(tree)")

        try await ReactNativeEnvironmentTests.withTemporaryDirectory { directory in
            try #"{ "ids": ["mask-rule-test-balance-amount", "mask-rule-test-card"] }"#.write(
                to: directory.appendingPathComponent("offsider.mask.json"), atomically: true, encoding: .utf8
            )

            let summary = try await Self.runIn(directory, "describe-ui --summary", platform: platform).stdout
            #expect(summary.contains("Balance [redacted] Details"), "\(summary)")
            #expect(!summary.contains(Self.amount), "\(summary)")
            #expect(!summary.contains(Self.holder), "\(summary)")

            let full = try await Self.runIn(directory, "describe-ui", platform: platform).stdout
            #expect(!full.contains(Self.amount) && !full.contains(Self.holder))
            try Self.expectTreeCacheHolds(none: [Self.amount, Self.holder])

            let shot = directory.appendingPathComponent("nested.png").path
            let capture = try await Self.runIn(directory, "screenshot --scale points --json --output \(AndroidE2E.quote(shot))", platform: platform)
            let report = try JSONDecoder().decode(ReactNativeEvidenceTests.Shot.self, from: Data(capture.stdout.utf8))
            #expect(report.maskedBy?["id"] == 2, "\(capture.stdout)")
            #expect(try Self.isBlack(at: try await app.frame(of: "mask-rule-test-balance-amount"), in: shot), "the nested amount was left unmasked")
            #expect(try Self.isBlack(at: try await app.frame(of: "mask-rule-test-card-holder"), in: shot), "text nested in the masked card was left unmasked")
        }
    }

    @Test("video refuses what a mask file names on screen, and writes nothing", arguments: RNPlatform.enabled)
    func videoRefusesMaskFileMatch(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("mask-sheet-test")
        try await ReactNativeEnvironmentTests.withTemporaryDirectory { directory in
            try #"{ "valuePatterns": ["bc1q"] }"#.write(to: directory.appendingPathComponent("offsider.mask.json"), atomically: true, encoding: .utf8)

            let video = directory.appendingPathComponent("file.mp4").path
            let recording = try await Self.recordVideo(to: video, in: directory, platform: platform)

            #expect(recording.exitCode == 1, "\(recording.stderr)")
            #expect(recording.stderr.contains("which offsider.mask.json masks"), "\(recording.stderr)")
            #expect(!FileManager.default.fileExists(atPath: video), "a refused recording wrote a file")
        }
    }

    @Test("on Android video warns over a Modal sheet, whose tree cannot prove what is drawn behind it, and not on the screen beneath", arguments: RNPlatform.enabled.filter { $0 == .android })
    func videoWarnsOnUnprovenTree(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("mask-sheet-test")
        try await ReactNativeEnvironmentTests.withTemporaryDirectory { directory in
            let plainVideo = directory.appendingPathComponent("plain.mp4").path
            let plain = try await Self.recordVideo(to: plainVideo, in: directory, platform: platform)
            #expect(plain.exitCode == 0, "\(plain.stderr)")
            #expect(!plain.stderr.contains("maskUnproven"), "\(plain.stderr)")

            try await app.run("tap --id mask-sheet-test-open-modal")
            try await app.run("wait --id mask-sheet-test-close --timeout 5")
            let modalVideo = directory.appendingPathComponent("modal.mp4").path
            let modal = try await Self.recordVideo(to: modalVideo, in: directory, platform: platform)
            #expect(modal.exitCode == 0, "\(modal.stderr)")
            #expect(modal.stderr.contains("a modal window covers the app"), "\(modal.stderr)")
            #expect(modal.stderr.contains("maskUnproven"), "\(modal.stderr)")
            #expect(FileManager.default.fileExists(atPath: modalVideo), "a warned recording still saves")
        }
    }
}
