import Foundation
import OffsiderCore
import Testing

@Suite("Log text")
struct LogTextTests {
    // Trimmed from `log show --style ndjson` in an iOS 27 simulator.
    static let springBoardLine = #"""
    {"timezoneName":"","messageType":"Info","eventType":"logEvent","source":null,"formatString":"Sending launch request: %{public}@","userID":501,"subsystem":"com.apple.runningboard","category":"general","threadID":626691,"processImagePath":"\/private\/var\/run\/com.apple.security.cryptexd\/mnt\/com.apple.iPhoneOS.SimulatorRuntime-v24.1.434.0.JBmYD8\/Library\/Developer\/CoreSimulator\/Profiles\/Runtimes\/iOS 27.0.simruntime\/Contents\/Resources\/RuntimeRoot\/System\/Library\/CoreServices\/SpringBoard.app\/SpringBoard","senderImagePath":"\/System\/Library\/PrivateFrameworks\/RunningBoardServices.framework\/RunningBoardServices","timestamp":"2026-10-02 22:17:19.556078+0930","eventMessage":"Sending launch request: <RBSLaunchRequest| osservice<com.apple.PosterBoard>; \"FBApplicationProcess\">","processID":63313,"parentActivityIdentifier":0}
    """#
    static let activityLine = #"""
    {"timezoneName":"","eventType":"activityCreateEvent","subsystem":"","category":"","processImagePath":"\/Applications\/PosterBoard.app\/PosterBoard","timestamp":"2026-10-02 22:17:19.553250+0930","eventMessage":"Loading Preferences From User Session CFPrefsD","processID":5222}
    """#
    static let reactNativeLine = #"""
    {"messageType":"Info","eventType":"logEvent","subsystem":"com.facebook.react.log","category":"javascript","processImagePath":"\/Users\/x\/Library\/Developer\/CoreSimulator\/Devices\/D\/data\/Containers\/Bundle\/Application\/A\/Playground.app\/Playground","timestamp":"2026-10-02 22:17:20.001000+0930","eventMessage":"\u001b[32mLOG\u001b[39m  tapped save","processID":4100}
    """#

    // MARK: Durations and times

    @Test("durations take ms, s, m and h, and a bare number is seconds", arguments: [
        ("500ms", Duration.milliseconds(500)),
        ("30s", .seconds(30)),
        ("2m", .seconds(120)),
        ("1h", .seconds(3600)),
        ("45", .seconds(45)),
        ("1.5", .milliseconds(1500)),
    ])
    func parsesDurations(text: String, expected: Duration) throws {
        #expect(try LogWindow.parseDuration(text) == expected)
    }

    @Test("a bad duration names the value and the accepted units", arguments: ["5x", "", "-3s", "0", "ms"])
    func rejectsBadDurations(text: String) {
        let error = #expect(throws: LogOptionError.self) { try LogWindow.parseDuration(text) }
        #expect(error?.message == "Invalid duration '\(text)'. Use a positive number with ms, s, m or h, such as 500ms, 30s, 2m or 1h.")
    }

    @Test("--since takes ISO 8601 with or without a zone, or epoch seconds")
    func parsesSince() throws {
        let adelaide = try #require(TimeZone(identifier: "Australia/Adelaide"))
        let expected = Date(timeIntervalSince1970: 1_790_945_238)
        #expect(try LogWindow.parseTime("2026-10-02T12:47:18Z") == expected)
        #expect(try LogWindow.parseTime("2026-10-02T22:17:18+09:30") == expected)
        #expect(try LogWindow.parseTime("2026-10-02 22:17:18", timeZone: adelaide) == expected)
        #expect(try LogWindow.parseTime("1790945238") == expected)
        #expect(throws: LogOptionError.self) { try LogWindow.parseTime("yesterday") }
    }

    // MARK: ANSI

    @Test("real and escaped colour codes are removed", arguments: [
        "\u{1B}[32mLOG\u{1B}[39m done",
        #"\u001b[32mLOG\u001b[39m done"#,
        #"\u001B[1;32mLOG\u001B[0m done"#,
        #"\x1b[32mLOG\x1b[39m done"#,
        #"\x1B[32mLOG\x1B[39m done"#,
        #"\033[32mLOG\033[0m done"#,
        #"\e[32mLOG\e[0m done"#,
    ])
    func stripsANSI(text: String) {
        #expect(LogText.stripANSI(text) == "LOG done")
    }

    @Test("ordinary backslashes and brackets survive")
    func keepsOrdinaryBackslashes() {
        let text = #"C:\temp\new [ok] \u0041 \e and \x1b alone"#
        #expect(LogText.stripANSI(text) == text)
    }

    // MARK: iOS

    @Test("an ndjson log event becomes an entry with the process name from its image path")
    func parsesLogEvent() throws {
        let entry = try #require(LogText.parseIOSNDJSON(Self.springBoardLine))
        #expect(entry.level == "Info")
        #expect(entry.process == "SpringBoard")
        #expect(entry.pid == 63313)
        #expect(entry.tag == "com.apple.runningboard:general")
        #expect(entry.message == #"Sending launch request: <RBSLaunchRequest| osservice<com.apple.PosterBoard>; "FBApplicationProcess">"#)
        let timestamp = try #require(entry.timestamp)
        #expect(abs(timestamp.timeIntervalSince1970 - 1_790_945_239.556078) < 0.000_01)
    }

    @Test("React Native entries are tagged with their category")
    func parsesReactNativeEvent() throws {
        let entry = try #require(LogText.parseIOSNDJSON(Self.reactNativeLine))
        #expect(entry.tag == "javascript")
        #expect(entry.process == "Playground")
        #expect(entry.message == "\u{1B}[32mLOG\u{1B}[39m  tapped save")
        #expect(entry.raw == "\u{1B}[32mLOG\u{1B}[39m  tapped save")
    }

    @Test("activity events, the closing count and non-JSON lines are skipped", arguments: [
        activityLine,
        #"{"count":10549,"finished":1}"#,
        "Filtering the log data using \"process == \\\"SpringBoard\\\"\"",
        "",
    ])
    func skipsNonEntries(line: String) {
        #expect(LogText.parseIOSNDJSON(line) == nil)
    }

    @Test("each source has its predicate, and an extra predicate is ANDed")
    func predicates() {
        #expect(LogText.iosPredicate(for: .all, executable: nil) == nil)
        #expect(LogText.iosPredicate(for: .reactNative, executable: nil) == #"subsystem == "com.facebook.react.log""#)
        #expect(LogText.iosPredicate(for: .app("com.example.app"), executable: "Example") == #"process == "Example""#)
        #expect(LogText.iosPredicate(for: .process(#"My "App""#), executable: nil) == #"process == "My \"App\"""#)
        #expect(LogText.iosPredicate(for: .all, executable: nil, extra: "messageType == error") == "messageType == error")
        #expect(
            LogText.iosPredicate(for: .reactNative, executable: nil, extra: "messageType == error")
                == #"(subsystem == "com.facebook.react.log") AND (messageType == error)"#
        )
    }

    @Test("--rn --app reads React Native's subsystem or the app's process, so its own console lines come too")
    func reactNativeAppPredicate() {
        #expect(LogText.iosPredicate(for: .reactNative(app: "com.example.app"), executable: "Example")
            == #"subsystem == "com.facebook.react.log" OR process == "Example""#)
        #expect(LogText.iosPredicate(for: .reactNative(app: "com.example.app"), executable: "Example", extra: "messageType == error")
            == #"(subsystem == "com.facebook.react.log" OR process == "Example") AND (messageType == error)"#)
    }

    @Test("history uses log show with whole seconds or an epoch start, live uses stream, always ndjson with info and debug")
    func logArguments() {
        let flags = ["--style", "ndjson", "--info", "--debug"]
        #expect(LogText.iosLogArguments(window: .last(.seconds(30)), predicate: nil) == ["show", "--last", "30s"] + flags)
        #expect(LogText.iosLogArguments(window: .last(.milliseconds(500)), predicate: nil) == ["show", "--last", "1s"] + flags)
        #expect(
            LogText.iosLogArguments(window: .since(Date(timeIntervalSince1970: 1_790_945_238.9)), predicate: "process == \"X\"")
                == ["show", "--start", "@1790945238"] + flags + ["--predicate", "process == \"X\""]
        )
        #expect(LogText.iosLogArguments(window: .live(.seconds(3)), predicate: nil) == ["stream"] + flags)
    }

    @Test("history windows have a cutoff, live ones do not")
    func cutoffs() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(LogWindow.last(.milliseconds(500)).cutoff(now: now) == Date(timeIntervalSince1970: 999.5))
        #expect(LogWindow.since(Date(timeIntervalSince1970: 10)).cutoff(now: now) == Date(timeIntervalSince1970: 10))
        #expect(LogWindow.live(nil).cutoff(now: now) == nil)
    }

    // MARK: Output

    @Test("the human line is time, level, process[pid], tag and message, leaving out what is missing")
    func formats() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let full = LogEntry(timestamp: Date(timeIntervalSince1970: 1_790_945_238.25), level: "Info", process: "SpringBoard", pid: 1, tag: "javascript", message: "hi")
        #expect(LogText.format(full, timeZone: utc) == "12:47:18.250Z Info    SpringBoard[1] javascript: hi")
        #expect(LogText.format(LogEntry(level: "Warning", pid: 7, tag: "ReactNativeJS", message: "careful"), timeZone: utc) == "Warning [7] ReactNativeJS: careful")
        #expect(LogText.format(LogEntry(message: "bare"), timeZone: utc) == "bare")
    }

    @Test("text times carry the zone's offset at that moment: Adelaide in summer and in winter, and a negative zone", arguments: [
        ("Australia/Adelaide", 1_791_343_402.25, "13:53:22.250+10:30"),
        ("Australia/Adelaide", 1_782_885_202.5, "15:23:22.500+09:30"),
        ("America/New_York", 1_791_343_402.0, "23:23:22.000-04:00"),
    ])
    func zoneOffsets(zone: String, seconds: Double, expected: String) throws {
        let timeZone = try #require(TimeZone(identifier: zone))
        #expect(LogText.format(LogEntry(timestamp: Date(timeIntervalSince1970: seconds), message: "x"), timeZone: timeZone) == expected + " x")
    }

    @Test("a device clock within 3 s of the Mac's is no skew; beyond it, the note says which way and how far")
    func clockSkew() {
        let now = Date(timeIntervalSince1970: 1_791_343_402.4)
        #expect(LogClock.skew(deviceSeconds: 1_791_343_405, hostNow: now) == nil)
        #expect(LogClock.skew(deviceSeconds: 1_791_345_202, hostNow: now) == 1800)
        #expect(LogClock.skew(deviceSeconds: 1_791_343_392, hostNow: now) == -10)
        #expect(LogClock.note(1800, device: "RFCRA0TCR5B") == "Note: RFCRA0TCR5B's clock is 1800 s ahead of this Mac's. Log times are the device's own; --last and --since were counted back from its clock.")
        #expect(LogClock.note(-10, device: "X").contains("10 s behind this Mac's"))
    }
}

@Suite("Log retention")
struct LogRetentionTests {
    static let cutoff = Date(timeIntervalSince1970: 1_791_343_000)

    static func entry(_ level: String, after seconds: TimeInterval) -> LogEntry {
        LogEntry(timestamp: cutoff.addingTimeInterval(seconds), level: level, message: "m")
    }

    static func retention(_ entries: [LogEntry]) -> LogRetention {
        var retention = LogRetention()
        entries.forEach { retention.add($0) }
        return retention
    }

    @Test("Info entries that begin 50 s into a window with older Default entries get the warning, naming the time and the gap")
    func warns() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let retention = Self.retention([Self.entry("Default", after: 2), Self.entry("Info", after: 50), Self.entry("Debug", after: 55)])
        #expect(retention.warning(cutoff: Self.cutoff, timeZone: utc) == "Warning: the oldest Info or Debug entry is from 03:17:30.000Z, 50 s after the window starts, while Default and Error entries go back further: iOS keeps Info and Debug entries only briefly. Read sooner after the action, or collect live with --duration or --follow.")
    }

    @Test("no warning when Info starts near the window's start, nothing older was kept, or a level is missing", arguments: [
        [("Default", 2.0), ("Info", 5.0)],
        [("Error", 45.0), ("Info", 50.0)],
        [("Info", 50.0)],
        [("Default", 2.0), ("Warning", 50.0)],
    ])
    func quiet(levels: [(String, Double)]) {
        #expect(Self.retention(levels.map { Self.entry($0.0, after: $0.1) }).warning(cutoff: Self.cutoff) == nil)
    }
}
