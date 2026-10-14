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

        #expect(line == #"{"version":1,"platform":"ios","device":"UDID","entries":[{"timestamp":"2026-10-02T12:47:18.250Z","level":"Info","process":"Playground","pid":4100,"tag":"javascript","message":"saved \"draft\"","raw":"\u001b[32msaved\u001b[39m \"draft\"","truncated":false},{"timestamp":null,"level":null,"process":null,"pid":null,"tag":null,"message":"bare","raw":null,"truncated":false}],"truncated":2,"redacted":0,"excluded":0}"#)
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
        #expect(lines[0].hasSuffix(#""message":"one","raw":"1790945238.399  4100  4120 I ReactNativeJS: one","truncated":false}"#))
        #expect(lines[1].hasSuffix(#""raw":null,"truncated":false}"#))
    }

    // MARK: Redaction

    private static let secretLine = #"batch-login {"email":"e2e@example.com","password":"hunter22"}"#

    @Test("redaction is on by default and with --raw, and off only with --no-redact", arguments: [
        ([String](), true), (["--no-redact"], false), (["--raw"], true), (["--raw", "--no-redact"], false), (["--redact"], true),
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

    @Test("the report counts redacted values, and the stderr footer names what was redacted without a way round it")
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
        #expect(lines[0].hasSuffix(#""redacted":0,"excluded":0}"#))

        #expect(Logs.redactionFooter(3) == "Redacted 3 values (passwords, tokens, emails, addresses, cards, phrases, codes).")
        #expect(Logs.redactionFooter(3)?.contains("--no-redact") == false)
        #expect(Logs.redactionFooter(0) == nil)
    }

    @Test("--raw keeps colour codes in text output but escapes other sequences, and still redacts")
    @MainActor
    func rawKeepsColourOnly() async throws {
        let message = "\u{1B}[32mok\u{1B}[0m \u{1B}]52;c;ZXZpbA==\u{07} password=hunter22\nnext"
        let backend = FakeLogBackend(entries: [LogEntry(message: message)])
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        var lines: [String] = []
        try await Self.command(["--raw", "--app", "com.example.playground"]).read(from: DeviceRouter.Route(backend: backend, device: device), note: { _ in }) { lines.append($0) }
        let line = try #require(lines.first)
        #expect(line.contains("\u{1B}[32mok\u{1B}[0m"))
        #expect(line.contains(#"\u001b]52;c;ZXZpbA==\u0007"#))
        #expect(!line.contains("\u{07}"))
        #expect(line.contains("password=[redacted]"))
        #expect(line.contains(#"\nnext"#))
        #expect(!line.contains("\n"))
    }

    @Test("a read of the whole device's log prints one stderr note; a scoped read prints none", arguments: [
        ([String](), true), (["--app", "com.example.playground"], false), (["--rn"], false), (["--process", "SpringBoard"], false),
    ])
    @MainActor
    func wholeLogNote(arguments: [String], noted: Bool) async throws {
        let backend = FakeLogBackend(entries: [LogEntry(message: "plain")])
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        var notes: [String] = []
        try await Self.command(arguments).read(from: DeviceRouter.Route(backend: backend, device: device), note: { notes.append($0) }) { _ in }
        #expect(notes.filter { $0 == Logs.wholeLogNote }.count == (noted ? 1 : 0))
    }

    @Test("an empty result is an empty entries array")
    func emptyReport() {
        #expect(LogReport(platform: .android, device: "emulator-5554", entries: [], truncated: 0).jsonLine()
            == #"{"version":1,"platform":"android","device":"emulator-5554","entries":[],"truncated":0,"redacted":0,"excluded":0}"#)
    }

    // MARK: Cut messages

    /// Runs `logs` over scripted entries, returning what went to stdout and to stderr.
    @MainActor
    private static func read(_ arguments: [String], entries: [LogEntry], platform: DevicePlatform = .android) async throws -> (stdout: [String], notes: [String]) {
        let backend = FakeLogBackend(platform: platform, entries: entries)
        let device = DeviceID(rawValue: platform == .ios ? "fake-device" : "emulator-5554", platform: platform)
        var stdout: [String] = []
        var notes: [String] = []
        try await command(arguments).read(from: DeviceRouter.Route(backend: backend, device: device), note: { notes.append($0) }, write: { stdout.append($0) })
        return (stdout, notes)
    }

    private static func report(_ line: String?) throws -> [String: Any] {
        let line = try #require(line)
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    static let cutMessage = String(repeating: "x", count: 1015) + "<\u{2026}>"

    @Test("an entry iOS cut short has truncated true in JSON with its message byte for byte; the report's own truncated still counts --max-lines drops")
    @MainActor
    func truncatedJSONField() async throws {
        let lines = try [Self.cutMessage, "tapped save", "tapped cancel"].map(LogTextTests.reactNativeEvent)
        let (stdout, _) = try await Self.read(["--json", "--max-lines", "2"], entries: lines.compactMap(LogText.parseIOSNDJSON), platform: .ios)
        let object = try Self.report(stdout.first)
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(entries.map { $0["truncated"] as? Bool } == [false, false])
        #expect(object["truncated"] as? Int == 1)

        let (all, _) = try await Self.read(["--json"], entries: lines.compactMap(LogText.parseIOSNDJSON), platform: .ios)
        let first = try #require((try Self.report(all.first)["entries"] as? [[String: Any]])?.first)
        #expect(first["truncated"] as? Bool == true)
        #expect(first["message"] as? String == Self.cutMessage)
        #expect(first["raw"] as? String == Self.cutMessage)
    }

    @Test("a cut entry's text line ends <…> [truncated], and stderr counts cut entries and points at rn logbox open")
    @MainActor
    func truncatedTextAndFooter() async throws {
        let entries = [LogEntry(message: Self.cutMessage, truncated: true), LogEntry(message: "whole"), LogEntry(message: "y" + Self.cutMessage, truncated: true)]
        let (stdout, notes) = try await Self.read([], entries: entries, platform: .ios)
        #expect(try #require(stdout.first).components(separatedBy: "\n") == [Self.cutMessage + " [truncated]", "whole", "y" + Self.cutMessage + " [truncated]"])
        #expect(notes.contains("2 entries were cut by iOS's log, which keeps about 1 KB of a message (they end <\u{2026}>); the rest was never stored. In a debug build, rn logbox open shows the whole error."))

        let (_, one) = try await Self.read(["--follow"], entries: Array(entries.prefix(2)), platform: .ios)
        #expect(one.contains { $0.hasPrefix("1 entry was cut by iOS's log") && $0.contains("(it ends <\u{2026}>)") })
        let (_, none) = try await Self.read([], entries: [LogEntry(message: "whole")], platform: .ios)
        #expect(!none.contains { $0.contains("cut by iOS's log") })
    }

    // MARK: Exclude

    /// One `console.warn` twice, as React Native's and as a console-wrapping SDK's copy, then an unrelated line.
    static let consoleCopies = [
        LogEntry(tag: "javascript", message: "\u{1B}[33mWARN\u{1B}[39m slow render"),
        LogEntry(tag: "com.example.monitor:copy", message: "Wrapper.m:41 [MIRROR] warn: slow render"),
        LogEntry(tag: "javascript", message: "LOG tapped save"),
    ]

    @Test("--exclude drops what --grep kept, matching case-insensitively, and counts only those drops")
    func excludeAfterGrep() throws {
        var collector = try LogCollector(maxLines: 0, grep: "slow", exclude: [#"\[mirror\]"#], keepsANSI: false)
        Self.consoleCopies.forEach { collector.add($0) }
        #expect(collector.entries.map(\.message) == ["WARN slow render"])
        #expect(collector.excluded == 1)
        #expect(collector.matched == 1)
    }

    @Test("--exclude matches the message after colour codes are removed, real or escaped")
    func excludeAfterStripping() throws {
        var collector = try LogCollector(maxLines: 0, grep: nil, exclude: ["^warn slow"], keepsANSI: true)
        collector.add(Self.consoleCopies[0])
        collector.add(LogEntry(message: #"\u001b[33mWARN\u001b[39m slow list"#))
        collector.add(Self.consoleCopies[2])
        #expect(collector.entries.map(\.message) == ["LOG tapped save"])
        #expect(collector.excluded == 2)
    }

    @Test("--exclude repeats, and an entry matching any of them is dropped")
    func repeatedExclude() throws {
        var collector = try Self.command(["--exclude", "MIRROR", "--exclude", "tapped"]).collector()
        Self.consoleCopies.forEach { collector.add($0) }
        #expect(collector.entries.map(\.message) == ["WARN slow render"])
        #expect(collector.excluded == 2)
    }

    @Test("--follow never prints an excluded entry, and stderr counts the drops")
    @MainActor
    func excludeWhileFollowing() async throws {
        let (stdout, notes) = try await Self.read(["--follow", "--exclude", #"\[MIRROR\]"#], entries: Self.consoleCopies)
        #expect(stdout == ["WARN slow render", "LOG tapped save"].map { "javascript: \($0)" })
        #expect(notes.contains("Excluded 1 entry (--exclude)."))
    }

    @Test("the JSON report counts excluded entries, and stderr says so only when there were some")
    @MainActor
    func excludedCount() async throws {
        let (stdout, notes) = try await Self.read(["--json", "--exclude", "mirror", "--exclude", "TAPPED"], entries: Self.consoleCopies)
        let object = try Self.report(stdout.first)
        #expect(object["excluded"] as? Int == 2)
        #expect((object["entries"] as? [Any])?.count == 1)
        #expect(notes.contains("Excluded 2 entries (--exclude)."))

        let (plain, quiet) = try await Self.read(["--json"], entries: Self.consoleCopies)
        #expect(try Self.report(plain.first)["excluded"] as? Int == 0)
        #expect(!quiet.contains { $0.hasPrefix("Excluded") })
    }

    @Test("an invalid --exclude pattern names --exclude, not --grep")
    func invalidExclude() {
        #expect(Self.validationMessage(["--grep", "ok", "--exclude", "("])?.hasPrefix("Invalid --exclude pattern: (.") == true)
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
