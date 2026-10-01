import Foundation
import Testing

@Suite("Android tap", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidTapTests {
    @Test("a coordinate tap lands at the dp point")
    func coordinates() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let result = try await AndroidE2E.run("tap -x 200 -y 400")
        #expect(result.stdout.contains("Tap at (200, 400) completed successfully"))
        _ = try await AndroidE2E.waitForLabel(of: "last-tap-coordinates") { $0 == "Tap Location: (200, 400)" }
        _ = try await AndroidE2E.waitForLabel(of: "tap-count") { $0 == "Tap Count: 1" }
    }

    @Test("--id taps the element, in both tap styles", arguments: ["simulator", "physical"])
    func byID(style: String) async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.run("tap --id tap-test-area --tap-style \(style)")
        _ = try await AndroidE2E.waitForLabel(of: "tap-count") { $0 == "Tap Count: 1" }
    }
}

@Suite("Android touch", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidTouchTests {
    @Test("touch --down and a later touch --up make one long press across two commands")
    func longPressAcrossCommands() async throws {
        try await AndroidE2E.open("touch-control", waitingFor: "touch-control-area")
        let point = try await AndroidE2E.centre(of: "touch-control-area")
        try await AndroidE2E.run("touch -x \(point.x) -y \(point.y) --down")
        try await Task.sleep(for: .milliseconds(1500))
        try await AndroidE2E.run("touch -x \(point.x) -y \(point.y) --up")
        _ = try await AndroidE2E.waitForLabel(of: "long-press-count") { $0 == "Long presses: 1" }
    }

    @Test("a held touch opens the context menu, and its item can be tapped")
    func contextMenu() async throws {
        try await AndroidE2E.open("context-menu-test", waitingFor: "context-menu-test-target")
        let point = try await AndroidE2E.centre(of: "context-menu-test-target")
        try await AndroidE2E.run("touch -x \(point.x) -y \(point.y) --down --up --delay 1.2")
        _ = try await AndroidE2E.waitForNode { $0["id"] as? String == "context-menu-test-favorite" }
        try await AndroidE2E.run("tap --id context-menu-test-favorite")
        let state = try await AndroidE2E.waitForLabel(of: "context-menu-test-state") { $0 != "Context Menu State: Initial" }
        #expect(state.contains("Favo"))
    }
}

@Suite("Android swipe and gesture", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidSwipeGestureTests {
    @Test("a swipe reports its start, end and direction in dp")
    func swipe() async throws {
        try await AndroidE2E.open("swipe-test", waitingFor: "swipe-test-area")
        try await AndroidE2E.run("swipe --start-x 200 --start-y 700 --end-x 200 --end-y 300 --duration 0.5")
        _ = try await AndroidE2E.waitForLabel(of: "swipe-count") { $0 == "Count: 1" }
        #expect(try await AndroidE2E.label(of: "last-swipe-direction") == "Direction: Up")
        #expect(try await AndroidE2E.label(of: "last-swipe-start") == "Start: (200, 700)")
    }

    @Test("the scroll-up preset is classified as scroll-up")
    func scrollUpPreset() async throws {
        try await AndroidE2E.open("gesture-presets", waitingFor: "gesture-detection-area")
        try await AndroidE2E.run("gesture scroll-up")
        _ = try await AndroidE2E.waitForLabel(of: "latest-gesture") { $0 == "Latest Gesture: scroll-up" }
    }
}

@Suite("Android key", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidKeyTests {
    @Test("key, key-sequence and key-combo reach the focused field")
    func keys() async throws {
        try await AndroidE2E.open("key-press", waitingFor: "key-press-field")
        try await AndroidE2E.run("tap --id key-press-field")
        try await AndroidE2E.run("key 4")
        _ = try await AndroidE2E.waitForLabel(of: "last-key-press") { $0 == "Last Key: a (4)" }

        try await AndroidE2E.run("key-sequence --keycodes 11,8,15,15,18")
        _ = try await AndroidE2E.waitForLabel(of: "key-press-count") { $0 == "Key Count: 6" }
        #expect(try await AndroidE2E.label(of: "last-key-press") == "Last Key: o (18)")

        try await AndroidE2E.run("key-combo --modifiers 225 --key 5")
        _ = try await AndroidE2E.waitForLabel(of: "last-key-press") { $0 == "Last Key: B (5)" }
    }
}
