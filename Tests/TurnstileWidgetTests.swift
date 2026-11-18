import Foundation
import Testing

/// `turnstile` on the playground's stand-in widget: local HTML in a web view that keeps its contents out of the tree, as the real widget does on iOS.
@Suite("Turnstile on the widget fixture", .serialized, .enabled(if: isE2EEnabled))
struct TurnstileWidgetTests {
    @Test("an unticked box reads checkbox, from points inside the web view")
    func untickedBox() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "widget-login")
        let status = try await Self.read()
        #expect(status["state"] as? String == "checkbox")
        #expect(status["source"] as? String == "web-view-points")
    }

    @Test("--wait on a box someone ticks lists each change with its time and ends on passed, with nothing sent to the widget")
    func waitSeesTheTick() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "widget-login-ticked")
        let started = Date()
        let output = try await TestHelpers.runOffsiderCommand("turnstile --wait 30 --json", simulatorUDID: try TestHelpers.requireSimulatorUDID())
        let status = try Self.json(in: output.output)
        #expect(status["state"] as? String == "passed")
        let changes = try #require(status["changes"] as? [[String: Any]])
        #expect(changes.first?["state"] as? String == "checkbox")
        #expect(changes.last?["state"] as? String == "passed")
        let passed = try #require(Self.date(status["lastPassed"]))
        #expect(passed >= started.addingTimeInterval(-1))
        #expect(output.output.contains("Turnstile: checkbox since "))
    }

    @Test("a pass that lapsed reads checkbox again, and the read says when it passed")
    func lapsedPass() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "widget-login-expiry")
        let started = Date()
        try await Self.tick()
        let passed = try await TestHelpers.runOffsiderCommand("turnstile --wait 10 --json", simulatorUDID: try TestHelpers.requireSimulatorUDID())
        #expect(try Self.json(in: passed.output)["state"] as? String == "passed")

        let lapsed = try await Self.poll(seconds: 12) { $0["state"] as? String == "checkbox" }
        let when = try #require(Self.date(lapsed["lastPassed"]))
        #expect(when >= started.addingTimeInterval(-1))
        let text = try await TestHelpers.runOffsiderCommand("turnstile", simulatorUDID: try TestHelpers.requireSimulatorUDID())
        #expect(text.output.contains("has reset since"))
    }

    @Test("a widget that fails when ticked reads failed, which --wait keeps waiting through")
    func failedWidget() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "widget-login-error")
        try await Self.tick()
        let failed = try await Self.poll(seconds: 8) { $0["state"] as? String == "failed" }
        #expect(failed["source"] as? String == "web-view-points")
        let waited = try await TestHelpers.runOffsiderCommandAllowFailure("turnstile --wait 2 --json", simulatorUDID: try TestHelpers.requireSimulatorUDID())
        #expect(waited.exitCode == 5)
    }

    /// The test's own hand on the stand-in box, where the read says it is. Offsider's commands never tick a widget themselves.
    private static func tick() async throws {
        let status = try await read()
        let frame = try #require(status["frame"] as? [String: Any])
        let x = try #require(frame["x"] as? Double) + (try #require(frame["width"] as? Double)) / 2
        let y = try #require(frame["y"] as? Double) + (try #require(frame["height"] as? Double)) / 2
        try await TestHelpers.runOffsiderCommand("tap -x \(x) -y \(y)", simulatorUDID: try TestHelpers.requireSimulatorUDID())
    }

    private static func read() async throws -> [String: Any] {
        try json(in: try await TestHelpers.runOffsiderCommand("turnstile --json", simulatorUDID: try TestHelpers.requireSimulatorUDID()).output)
    }

    private static func poll(seconds: TimeInterval, until done: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(seconds)
        var last: [String: Any] = [:]
        while Date() < deadline {
            last = try await read()
            if done(last) { return last }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TestError.unexpectedState("Turnstile never reached the state the test waits for within \(Int(seconds)) s. Last read: \(last)")
    }

    private static func json(in output: String) throws -> [String: Any] {
        let line = try #require(output.split(separator: "\n").last { $0.hasPrefix("{\"version\"") }, "no JSON line in: \(output)")
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
