import Foundation
import Testing

/// The Pixel 9 Pro Fold AVD: postures, the active display, the RN window readout, captures and input while folded.
@Suite("Android foldable", .serialized, .enabled(if: isAndroidFoldE2EEnabled))
struct AndroidFoldableTests {
    struct Screen: Decodable {
        let width: Double
        let height: Double
        let orientation: String
        let rotation: Int?
        let display: DisplayRef?
        let posture: String?
    }

    struct DisplayRef: Decodable {
        let id: String
    }

    struct Tree: Decodable {
        let screen: Screen
    }

    struct Capture: Decodable {
        let width: Int
        let height: Int
        let display: DisplayRef?
        let posture: String?
    }

    struct PostureReport: Decodable {
        let posture: String
        let display: String?
        let screen: Size?
    }

    struct Size: Decodable {
        let width: Double
        let height: Double
    }

    struct OrientationReport: Decodable {
        let orientation: String
        let rotation: Int
    }

    /// The expected dp size, the RN readout (React Native rounds the dp size), capture size and display for each settable posture.
    struct Expected {
        let width: Double
        let height: Double
        let window: String
        let pixels: (width: Int, height: Int)
        let display: String
    }

    static let open = Expected(width: 851.69, height: 882.87, window: "Window: 852x883", pixels: (2076, 2152), display: "inner")
    static let closed = Expected(width: 443.08, height: 994.46, window: "Window: 443x994", pixels: (1080, 2424), display: "cover")

    static func requireFoldAVD() throws {
        try #require(AndroidE2E.expectedAVD == AndroidE2E.foldAVD, "Set OFFSIDER_ANDROID_E2E_AVD=\(AndroidE2E.foldAVD) and OFFSIDER_ANDROID_DEVICE to that emulator.")
    }

    static func decode<T: Decodable>(_ type: T.Type, _ arguments: String) async throws -> T {
        try JSONDecoder().decode(type, from: Data(try await AndroidE2E.run(arguments).stdout.utf8))
    }

    static func screen() async throws -> Screen {
        try await decode(Tree.self, "describe-ui").screen
    }

    static func capture() async throws -> Capture {
        let output = AndroidE2E.temporaryFile("fold.png")
        defer { try? FileManager.default.removeItem(at: output) }
        return try await decode(Capture.self, "screenshot --json --output \(AndroidE2E.quote(output.path))")
    }

    /// Folding a Pixel puts "Swipe up to continue" over the app on the cover (its default for apps on fold), so swipe up as a user would.
    static func continueOnCover() async throws {
        let window = try await AndroidE2E.shell("dumpsys window | grep isKeyguardShowing || true", timeout: 30)
        if window.contains("isKeyguardShowing=true") {
            try await AndroidE2E.run("swipe --start-x 221 --start-y 960 --end-x 221 --end-y 400 --duration 0.3")
        }
    }

    /// Sets the posture, then checks the report, describe-ui's screen, the app's readout (its activity stays open and resizes) and a capture.
    static func fold(to posture: String, expecting expected: Expected) async throws {
        let report = try await decode(PostureReport.self, "posture \(posture) --timeout 30 --json")
        #expect(report.posture == posture)
        #expect(report.display == expected.display)
        #expect(report.screen.map { ($0.width, $0.height) } ?? (0, 0) == (expected.width, expected.height), "\(posture): posture reports \(String(describing: report.screen))")

        let screen = try await Self.screen()
        #expect((screen.width, screen.height) == (expected.width, expected.height), "\(posture): describe-ui reports \(screen.width) x \(screen.height)")
        #expect(screen.display?.id == expected.display)
        #expect(screen.posture == posture)

        var label: String?
        let shown = try await AndroidE2E.eventually(timeout: 30, every: .seconds(1)) {
            if posture == "closed" {
                try await continueOnCover()
            }
            label = try? await AndroidE2E.label(of: "environment-test-window")
            return label == expected.window
        }
        #expect(shown, "\(posture): the app's window reads \(label ?? "nothing"), expected \(expected.window)")

        let capture = try await Self.capture()
        #expect(capture.width == expected.pixels.width && capture.height == expected.pixels.height, "\(posture): \(capture.width) x \(capture.height)")
        #expect(capture.display?.id == expected.display)
        #expect(capture.posture == posture)
    }

    @Test("posture open, closed, open moves the screen, the app's window and captures between the inner and cover displays")
    func openClosedOpen() async throws {
        try Self.requireFoldAVD()
        try await AndroidE2E.run("orientation portrait --timeout 10")
        try await AndroidE2E.run("posture open --timeout 30")
        try await AndroidE2E.open("environment-test", waitingFor: "environment-test-screen")
        do {
            try await Self.fold(to: "open", expecting: Self.open)
            try await Self.fold(to: "closed", expecting: Self.closed)

            let before = try await AndroidE2E.label(of: "environment-test-log-count")
            let count = Int(before?.components(separatedBy: ": ").last ?? "") ?? -1
            try #require(count >= 0, "\(String(describing: before))")
            try await AndroidE2E.run("tap --id environment-test-log")
            _ = try await AndroidE2E.waitForLabel(of: "environment-test-log-count") { $0 == "Log Count: \(count + 1)" }

            try await Self.fold(to: "open", expecting: Self.open)
        } catch {
            _ = try? await AndroidE2E.run("posture open --timeout 30")
            throw error
        }
    }

    @Test("displays lists the cover and inner displays with the active one marked")
    func displays() async throws {
        try Self.requireFoldAVD()
        try await AndroidE2E.run("posture open --timeout 30")
        let json = try await AndroidE2E.run("displays --json").stdout
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let rows = try #require(object["displays"] as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["id"] as? String }) == ["cover", "inner"], "\(json)")
        #expect(rows.first { $0["active"] as? Bool == true }?["id"] as? String == "inner", "\(json)")
        #expect(object["posture"] as? String == "open")

        let inactive = try await AndroidE2E.offsider("describe-ui --display cover")
        #expect(inactive.exitCode != 0)
        #expect(inactive.stderr.contains("Fold the emulator with `offsider posture closed"), "\(inactive.stderr)")
    }

    @Test("orientation portrait turns the unfolded display and reports its rotation")
    func unfoldedOrientation() async throws {
        try Self.requireFoldAVD()
        try await AndroidE2E.run("posture open --timeout 30")
        let before = try await Self.decode(OrientationReport.self, "orientation --json")
        do {
            let turned = try await Self.decode(OrientationReport.self, "orientation portrait --timeout 10 --json")
            #expect(turned.orientation == "portrait")
            #expect(turned.rotation == 0)
            let screen = try await Self.screen()
            #expect(screen.rotation == turned.rotation, "describe-ui rotation \(String(describing: screen.rotation))")
            #expect(screen.display?.id == "inner")
            #expect(screen.orientation == (screen.width > screen.height ? "landscape" : "portrait"))
            try await AndroidE2E.run("orientation --rotation \(before.rotation) --timeout 10")
        } catch {
            _ = try? await AndroidE2E.run("orientation --rotation \(before.rotation) --timeout 10")
            throw error
        }
    }
}
