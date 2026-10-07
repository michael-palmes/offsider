import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Logs command")
struct LogsCommandTests {
    private static func entries(_ count: Int) -> [LogEntry] {
        (1...count).map { LogEntry(message: "line \($0)") }
    }

    private static func command(_ arguments: [String]) throws -> Logs {
        try Logs.parse(arguments + ["--device", "fake-device"])
    }

    private static func validationMessage(_ arguments: [String]) -> String? {
        do {
            _ = try command(arguments)
            return nil
        } catch {
            return Logs.message(for: error)
        }
    }

    // MARK: Collector

    @Test("--max-lines keeps the newest entries and counts the rest as truncated")
    func truncationKeepsNewest() throws {
        var collector = try LogCollector(maxLines: 3, grep: nil, keepsANSI: false)
        Self.entries(10).forEach { collector.add($0) }

        #expect(collector.entries.map(\.message) == ["line 8", "line 9", "line 10"])
        #expect(collector.truncated == 7)
    }

    @Test("--max-lines 0 keeps everything")
    func noLimit() throws {
        var collector = try LogCollector(maxLines: 0, grep: nil, keepsANSI: false)
        Self.entries(1200).forEach { collector.add($0) }

        #expect(collector.entries.count == 1200)
        #expect(collector.truncated == 0)
    }

    @Test("--follow passes matching entries through without keeping them")
    func followKeepsNothing() throws {
        var collector = try Self.command(["--follow", "--grep", "line 1"]).collector()
        let shown = Self.entries(5000).compactMap { collector.add($0) }

        #expect(shown.count == 1111)
        #expect(collector.entries.isEmpty)
    }

    @Test("--grep matches case-insensitively after colour codes are removed, and only matches count")
    func grepAfterStripping() throws {
        var collector = try LogCollector(maxLines: 1, grep: "log +tapped", keepsANSI: false)
        collector.add(LogEntry(message: #"\u001b[32mLOG\u001b[39m tapped save"#))
        collector.add(LogEntry(message: "\u{1B}[32mLOG\u{1B}[39m tapped cancel"))
        collector.add(LogEntry(message: "unrelated"))

        #expect(collector.entries.map(\.message) == ["LOG tapped cancel"])
        #expect(collector.truncated == 1)
    }

    @Test("--raw keeps colour codes in the message but still greps the stripped text")
    func rawKeepsCodes() throws {
        let collector = try LogCollector(maxLines: 10, grep: "^LOG saved$", keepsANSI: true)
        let shown = collector.filter(LogEntry(message: "\u{1B}[32mLOG\u{1B}[39m saved"))
        #expect(shown?.message == "\u{1B}[32mLOG\u{1B}[39m saved")
    }

    @Test("an invalid --grep pattern names the pattern")
    func invalidGrep() {
        #expect(Self.validationMessage(["--grep", "("])?.hasPrefix("Invalid --grep pattern: (.") == true)
    }

    // MARK: Live stream

    private struct StreamFailed: Error {}

    @Test("a live stream that exits on its own ends the wait with its status and points at --predicate")
    @MainActor
    func liveStreamExitFails() async throws {
        let clock = ScriptedClock()
        let error = await #expect(throws: CLIError.self) {
            try await LiveLogStream.run(
                for: nil, predicate: "messageType ==", clock: clock.poll,
                wait: { throw StreamFailed() }, exitStatus: { 64 }
            )
        }
        #expect(error?.userFacingDescription == "The simulator's log command exited with status 64. Check the --predicate syntax.")
    }

    @Test("a live window ends at its deadline without an error while the stream keeps running")
    @MainActor
    func liveWindowEndsAtDeadline() async throws {
        let clock = ScriptedClock()
        try await LiveLogStream.run(
            for: .seconds(5), predicate: nil, clock: clock.poll,
            wait: { try await Task.sleep(for: .seconds(3600)) }, exitStatus: { nil }
        )
        #expect(clock.now >= 5)
        #expect(clock.now < 6)
    }

    @Test("without --predicate the stream's failure names the status only")
    func failureWithoutPredicate() {
        let error = LiveLogStream.failure(StreamFailed(), status: 1, predicate: nil)
        #expect(error.userFacingDescription == "The simulator's log command exited with status 1.")
    }

    // MARK: JSON

    @Test("the JSON report has version, platform, device, entries with null for missing fields, and truncated")
    func reportShape() throws {
        let entries = [
            LogEntry(timestamp: Date(timeIntervalSince1970: 1_790_945_238.25), level: "Info", process: "Playground", pid: 4100, tag: "javascript", message: "saved \"draft\"", raw: "\u{1B}[32msaved\u{1B}[39m \"draft\""),
            LogEntry(message: "bare"),
        ]
        let line = LogReport(platform: .ios, device: "UDID", entries: entries, truncated: 2).jsonLine()

        #expect(line == #"{"version":1,"platform":"ios","device":"UDID","entries":[{"timestamp":"2026-10-02T12:47:18.250Z","level":"Info","process":"Playground","pid":4100,"tag":"javascript","message":"saved \"draft\"","raw":"\u001b[32msaved\u001b[39m \"draft\""},{"timestamp":null,"level":null,"process":null,"pid":null,"tag":null,"message":"bare","raw":null}],"truncated":2,"redacted":0}"#)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect((object["entries"] as? [Any])?.count == 2)
    }

    @Test("--raw off strips colour codes from the message but keeps them in raw")
    func rawKeepsCodesUnderStripping() throws {
        let collector = try LogCollector(maxLines: 10, grep: nil, keepsANSI: false)
        let shown = collector.filter(LogEntry(message: "\u{1B}[32mLOG\u{1B}[39m saved", raw: "\u{1B}[32mLOG\u{1B}[39m saved"))
        #expect(shown?.message == "LOG saved")
        #expect(shown?.raw == "\u{1B}[32mLOG\u{1B}[39m saved")
    }

    @Test("--follow --json prints one entry object per line, each with raw")
    @MainActor
    func followJSONLines() async throws {
        let backend = FakeLogBackend(entries: [
            LogEntry(level: "Info", tag: "ReactNativeJS", message: "one", raw: "1790945238.399  4100  4120 I ReactNativeJS: one"),
            LogEntry(message: "two"),
        ])
        var lines: [String] = []
        try await Self.command(["--follow", "--json"])
            .read(from: DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "emulator-5554", platform: .android))) { lines.append($0) }

        #expect(lines.count == 2)
        for line in lines {
            #expect(!line.contains("\n"))
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object.keys.contains("raw"))
        }
        #expect(lines[0].hasSuffix(#""message":"one","raw":"1790945238.399  4100  4120 I ReactNativeJS: one"}"#))
        #expect(lines[1].hasSuffix(#""raw":null}"#))
    }

    // MARK: Redaction

    private static let secretLine = #"batch-login {"email":"e2e@example.com","password":"hunter22"}"#

    @Test("redaction is on by default, off with --no-redact or --raw alone, and on with --raw --redact", arguments: [
        ([String](), true), (["--no-redact"], false), (["--raw"], false), (["--raw", "--redact"], true), (["--redact"], true),
    ])
    func redactionFlags(arguments: [String], redacts: Bool) throws {
        #expect(try Self.command(arguments).collector().redacts == redacts)
    }

    @Test("--grep matches the unredacted text, then the message and raw line are redacted and counted")
    func grepBeforeRedaction() throws {
        var collector = try LogCollector(maxLines: 10, grep: "hunter22", keepsANSI: false, redacts: true)
        collector.add(LogEntry(message: Self.secretLine, raw: "1790945238.399  4100  4120 I ReactNativeJS: " + Self.secretLine))

        let entry = try #require(collector.entries.first)
        #expect(entry.message == #"batch-login {"email":"[redacted]","password":"[redacted]"}"#)
        #expect(entry.raw?.hasSuffix(#"{"email":"[redacted]","password":"[redacted]"}"#) == true)
        #expect(collector.redacted == 2)
    }

    @Test("the report counts redacted values, and the stderr footer names --no-redact")
    @MainActor
    func reportCountsRedactions() async throws {
        let backend = FakeLogBackend(entries: [LogEntry(message: Self.secretLine), LogEntry(message: "plain")])
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        var lines: [String] = []
        try await Self.command(["--json"]).read(from: DeviceRouter.Route(backend: backend, device: device)) { lines.append($0) }
        let first = try #require(lines.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        #expect(object["redacted"] as? Int == 2)
        #expect(!lines[0].contains("hunter22"))

        lines = []
        try await Self.command(["--json", "--no-redact"]).read(from: DeviceRouter.Route(backend: backend, device: device)) { lines.append($0) }
        #expect(lines[0].contains("hunter22"))
        #expect(lines[0].hasSuffix(#""redacted":0}"#))

        #expect(Logs.redactionFooter(3) == "Redacted 3 values (passwords, tokens, emails); --no-redact shows them.")
        #expect(Logs.redactionFooter(0) == nil)
    }

    @Test("an empty result is an empty entries array")
    func emptyReport() {
        #expect(LogReport(platform: .android, device: "emulator-5554", entries: [], truncated: 0).jsonLine()
            == #"{"version":1,"platform":"android","device":"emulator-5554","entries":[],"truncated":0,"redacted":0}"#)
    }

    // MARK: Flags

    @Test("the default window is the last 30 seconds of everything")
    func defaults() throws {
        let query = try Self.command([]).query()
        #expect(query == LogQuery(source: .all, window: .last(.seconds(30))))
    }

    @Test("each flag maps to its source and window")
    func flagMapping() throws {
        #expect(try Self.command(["--rn", "--duration", "3"]).query() == LogQuery(source: .reactNative, window: .live(.seconds(3))))
        #expect(try Self.command(["--app", "com.example", "--follow"]).query() == LogQuery(source: .app("com.example"), window: .live(nil)))
        #expect(try Self.command(["--process", "SpringBoard", "--last", "2m", "--predicate", "messageType == error"]).query()
            == LogQuery(source: .process("SpringBoard"), window: .last(.seconds(120)), predicate: "messageType == error"))
        #expect(try Self.command(["--since", "1790945238"]).query().window == .since(Date(timeIntervalSince1970: 1_790_945_238)))
        #expect(try Self.command(["--rn", "--app", "com.example", "--last", "2m"]).query() == LogQuery(source: .reactNative(app: "com.example"), window: .last(.seconds(120))))
    }

    @Test("a --rn read without --app that finds few entries suggests --app, naming the platform's id")
    func appHint() {
        #expect(Logs.appHint(for: .reactNative, matched: 2, platform: .ios) == "Only 2 React Native entries. An app's console output can log under its own process instead; add --app <bundle-id> to read both.")
        #expect(Logs.appHint(for: .reactNative, matched: 0, platform: .android)?.hasSuffix("add --app <package> to read both.") == true)
        #expect(Logs.appHint(for: .reactNative, matched: 5, platform: .ios) == nil)
        #expect(Logs.appHint(for: .reactNative, matched: 1, grepping: true, platform: .ios) == nil)
        #expect(Logs.appHint(for: .reactNative, matched: 0, grepping: true, platform: .ios) != nil)
        #expect(Logs.appHint(for: .reactNative(app: "com.example"), matched: 0, platform: .ios) == nil)
        #expect(Logs.appHint(for: .all, matched: 0, platform: .ios) == nil)
    }

    @Test("conflicting flags are named", arguments: [
        (["--rn", "--process", "x"], "--process reads one process alone: drop --rn, or drop --process. --rn and --app combine."),
        (["--rn", "--app", "x", "--process", "y"], "--process reads one process alone: drop --rn and --app, or drop --process. --rn and --app combine."),
        (["--last", "1m", "--follow"], "Use only one of --last, --since, --duration or --follow; got --last and --follow."),
        (["--since", "0", "--duration", "2"], "Use only one of --last, --since, --duration or --follow; got --since and --duration."),
    ])
    func conflicts(arguments: [String], message: String) {
        #expect(Self.validationMessage(arguments) == message)
    }

    @Test("--duration must be from 1 to 300 seconds", arguments: ["0.5", "301"])
    func durationRange(value: String) {
        #expect(Self.validationMessage(["--duration", value]) == "--duration must be from 1 to 300 seconds; use --follow to stream until interrupted.")
    }

    @Test("--last beyond 365 days is refused instead of overflowing, while a normal duration still works")
    func lastUpperBound() throws {
        #expect(Self.validationMessage(["--last", "1e300"]) == "Duration '1e300' is too long. Use up to 8760h (365 days).")
        #expect(Self.validationMessage(["--last", "8761h"]) == "Duration '8761h' is too long. Use up to 8760h (365 days).")
        #expect(try Self.command(["--last", "1h"]).query().window == .last(.seconds(3600)))
        #expect(try Self.command(["--last", "8760h"]).query().window == .last(.seconds(31_536_000)))
    }

    @Test("--since past year 9999 is refused instead of overflowing")
    func sinceUpperBound() throws {
        let message = "--since time '1e300' is too far in the future. Use a time up to 9999-12-31T23:59:59Z (253402300799 seconds since 1970)."
        #expect(Self.validationMessage(["--since", "1e300"]) == message)
        #expect(Self.validationMessage(["--since", "253402300800"]) != nil)
        let latest = try Self.command(["--since", "9999-12-31T23:59:59Z"]).query().window
        #expect(LogText.iosLogArguments(window: latest, predicate: nil).prefix(3) == ["show", "--start", "@253402300799"])
    }

    @Test("--max-lines below 0 is rejected")
    func negativeMaxLines() {
        #expect(Self.validationMessage(["--max-lines=-1"]) == "--max-lines must be 0 (no limit) or more; got -1.")
    }
}
