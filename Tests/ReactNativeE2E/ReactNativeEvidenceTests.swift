import CoreGraphics
import Foundation
import ImageIO
import OffsiderCore
import Testing

@Suite("React Native evidence", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeEvidenceTests {
    struct Shot: Decodable {
        let masked: Int?
        let maskedBy: [String: Int]?
        let changedPixels: Int?
        let changedBounds: Bounds?
        let diffPath: String?
    }

    struct Bounds: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct LogReport: Decodable {
        struct Entry: Decodable {
            let message: String
            let raw: String?
        }
        let entries: [Entry]
        let redacted: Int
    }

    static let email = "e2e@example.com"

    /// Opens the text input fixture with `email` typed into its field, then clears it after `body`.
    static func withTypedEmail<T>(_ app: RNApp, _ body: () async throws -> T) async throws -> T {
        try await app.open("text-input")
        try await app.run("tap --id text-input-field")
        try await app.run("type --replace \(email)")
        do {
            let result = try await body()
            _ = try? await app.run("type --replace ''")
            return result
        } catch {
            _ = try? await app.run("type --replace ''")
            throw error
        }
    }

    static func pixel(atPoint point: (x: Double, y: Double), in path: String) throws -> [UInt8] {
        let image = try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        return ScreenshotMaskTests.pixel(image, Int(point.x), Int(point.y))
    }

    @Test("--mask-emails and --mask-id black out the field holding an email address", arguments: RNPlatform.enabled)
    func masksEmailField(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.withTypedEmail(app) {
            let field = try await app.frame(of: "text-input-field")
            let centre = (x: field.x + field.width / 2, y: field.y + field.height / 2)
            try await ReactNativeEnvironmentTests.withTemporaryDirectory { directory in
                for (flags, kind) in [("--mask-emails", "emails"), ("--mask-id text-input-field", "id")] {
                    let output = directory.appendingPathComponent("\(kind).png").path
                    let json = try await app.run("screenshot \(flags) --scale points --json --output \(AndroidE2E.quote(output))").stdout
                    let shot = try JSONDecoder().decode(Shot.self, from: Data(json.utf8))
                    #expect((shot.maskedBy?[kind] ?? 0) >= 1, "\(flags): \(json)")
                    #expect(try Self.pixel(atPoint: centre, in: output) == [0, 0, 0], "\(flags) left the field's centre unmasked")
                }
            }
        }
    }

    @Test("--compare --diff-output counts the pixels that changed inside the field", arguments: RNPlatform.enabled)
    func diffOverlapsField(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("text-input")
        try await app.run("tap --id text-input-field")
        try await app.run("type --replace ''")
        let field = try await app.frame(of: "text-input-field")
        try await ReactNativeEnvironmentTests.withTemporaryDirectory { directory in
            let baseline = directory.appendingPathComponent("before.png").path
            let diff = directory.appendingPathComponent("diff.png").path
            try await app.run("screenshot --scale points --output \(AndroidE2E.quote(baseline))")
            try await app.run("type --replace \(Self.email)")
            let result = try await app.offsider("screenshot --scale points --json --compare \(AndroidE2E.quote(baseline)) --diff-output \(AndroidE2E.quote(diff))")
            #expect(result.exitCode == 0, "\(result.stderr)")
            let shot = try JSONDecoder().decode(Shot.self, from: Data(result.stdout.utf8))
            #expect(FileManager.default.fileExists(atPath: diff))
            #expect((shot.changedPixels ?? 0) > 0)
            let bounds = try #require(shot.changedBounds)
            let overlaps = bounds.x < field.x + field.width && field.x < bounds.x + bounds.width
                && bounds.y < field.y + field.height && field.y < bounds.y + bounds.height
            #expect(overlaps, "changed bounds \(bounds) miss the field \(field)")
        }
        try await app.run("type --replace ''")
    }

    @Test("logs --rn --app finds the interval line, on Android also after the app was stopped and started again", arguments: RNPlatform.enabled)
    func logsReactNativeAndApp(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("live-ticker")
        try await app.run("tap --id live-ticker-interval-1w")
        if platform == .android {
            try await AndroidE2E.shell("am force-stop \(AndroidE2E.package)")
            try await app.open("live-ticker")
        }

        var found = ""
        let deadline = Date().addingTimeInterval(15)
        repeat {
            found = try await app.run("logs --rn --app \(IOSRNPlayground.bundleID) --last 2m --grep 'Interval Selected'").stdout
            if found.contains("OffsiderFixture Interval Selected 1W") { break }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        #expect(found.contains("OffsiderFixture Interval Selected 1W"), "\(found)")
    }

    @Test("logs --rn redacts the login's email and password by default, and --no-redact shows them", arguments: RNPlatform.enabled)
    func logsRedactLogin(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("batch-login-flow", waitingFor: "batch-login-email-field")
        try await app.run("type --into-id batch-login-email-field --replace \(Self.email)")
        try await app.run("tap --id batch-login-continue")
        _ = try await app.waitForNode { $0["id"] as? String == "batch-login-password-field" }
        try await app.run("type --into-id batch-login-password-field --replace Hunter22")
        try await app.run("tap --id batch-login-sign-in")

        var report: LogReport?
        let deadline = Date().addingTimeInterval(15)
        repeat {
            let json = try await app.run("logs --rn --last 1m --json --grep 'OffsiderFixture batch-login'").stdout
            report = try JSONDecoder().decode(LogReport.self, from: Data(json.utf8))
            if report?.entries.isEmpty == false { break }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline

        let found = try #require(report)
        let entry = try #require(found.entries.last, "no batch-login log entry")
        #expect(entry.message.contains(#""email":"[redacted]""#), "\(entry.message)")
        #expect(entry.message.contains(#""password":"[redacted]""#), "\(entry.message)")
        #expect(!(entry.raw ?? "").contains("Hunter22"))
        #expect(found.redacted >= 2)

        let plain = try await app.run("logs --rn --last 1m --no-redact --grep 'OffsiderFixture batch-login'").stdout
        #expect(plain.contains(Self.email))
    }
}
