import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android logs")
@MainActor
struct AndroidLogsTests {
    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    nonisolated static let dump = """
    --------- beginning of main
             1790945238.399  4100  4120 I ReactNativeJS: \u{1B}[32mLOG\u{1B}[39m tapped save
             1790945238.512  4100  4120 W ReactNativeJS: careful: slow
             1790945238.600  4100  4133 E ReactNative: Exception in native call
    --------- beginning of crash

    """

    /// `-v uid` lines: the playground (10213) before and after a restart, system noise, and another React Native app.
    nonisolated static let uidDump = """
    --------- beginning of main
             1790945238.399 10213  4100  4120 I ReactNativeJS: tapped save
             1790945238.450 10213  4100  4121 I OffsiderPlayground: [CONSOLE] Size Selected S
             1790945238.500  1000   677   874 D WifiScoreCard: noise
             1790945238.600 10213  5200  5201 I ReactNativeJS: after restart
             1790945238.700 10099  6000  6001 I ReactNativeJS: another app

    """

    /// Records every shell command and answers the one script: its preamble as the device would print it, then a dump.
    static func server(pid: String? = "4100", packages: String = "package:com.example.app.extra uid:10300\npackage:com.example.app uid:10213\n") -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang }
        ) { _, service in
            let command = String(service.dropFirst("shell,v2,raw:".count))
            if command.contains("pidof") {
                guard let pid else { return FakeAdbServer.shell(stdout: "offsider-not-running\n", status: 3) }
                return FakeAdbServer.shell(stdout: "offsider-pid \(pid)\noffsider-logcat\n" + dump)
            }
            if command.contains("list packages -U") {
                return FakeAdbServer.shell(stdout: packages + "offsider-logcat\n" + uidDump)
            }
            return FakeAdbServer.shell(stdout: "offsider-logcat\n" + dump)
        })
    }

    static func read(_ query: LogQuery, from server: FakeAdbServer) async throws -> [LogEntry] {
        let backend = AndroidBackend(host: AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)) { _, _ in }
        var entries: [LogEntry] = []
        try await backend.readLogs(query, on: device) { entries.append($0) }
        return entries
    }

    static func shellCommands(_ server: FakeAdbServer) -> [String] {
        server.services.filter { $0.hasPrefix("shell,v2,raw:") }.map { String($0.dropFirst("shell,v2,raw:".count)) }
    }

    // MARK: Parser

    @Test("epoch threadtime lines become entries with exact Unix times, level names, pid and tag; separators are skipped")
    func parsesThreadtime() throws {
        var parser = LogcatParser()
        let entries = Self.dump.split(separator: "\n", omittingEmptySubsequences: false).compactMap { parser.parse(String($0)) }

        #expect(entries.count == 3)
        let timestamp = try #require(entries[0].timestamp)
        #expect(abs(timestamp.timeIntervalSince1970 - 1_790_945_238.399) < 0.000_1)
        #expect(entries[0].level == "Info")
        #expect(entries[0].pid == 4100)
        #expect(entries[0].tag == "ReactNativeJS")
        #expect(entries[0].message == "\u{1B}[32mLOG\u{1B}[39m tapped save")
        #expect(entries[1].level == "Warning")
        #expect(entries[1].message == "careful: slow")
        #expect(entries[2].tag == "ReactNative")
        #expect(entries[2].level == "Error")
        #expect(entries[0].raw == Self.dump.split(separator: "\n").first { $0.contains("tapped save") }.map(String.init))
    }

    @Test("the uid column -v uid adds is read, and lines without it still parse")
    func uidColumn() {
        var parser = LogcatParser()
        let entry = parser.parse("         1790945238.399 10213  4100  4120 I ReactNativeJS: tapped save")
        #expect(parser.lastUID == "10213")
        #expect(entry?.pid == 4100 && entry?.tag == "ReactNativeJS" && entry?.message == "tapped save")
        _ = parser.parse("1790945238.399  4100  4120 I ReactNativeJS: no uid")
        #expect(parser.lastUID == nil)
    }

    @Test("a padded tag is trimmed and an empty message is kept empty")
    func paddedTag() {
        var parser = LogcatParser()
        let entry = parser.parse("1790945238.399  1234  1250 D Zygote  :")
        #expect(entry?.tag == "Zygote")
        #expect(entry?.message == "")
    }

    @Test("a line without a header continues the previous entry")
    func continuationLine() {
        var parser = LogcatParser()
        _ = parser.parse("1790945238.399  4100  4120 E ReactNativeJS: TypeError: undefined is not a function")
        let continuation = parser.parse("    at onPress (index.bundle:1:2)")

        #expect(continuation?.message == "    at onPress (index.bundle:1:2)")
        #expect(continuation?.tag == "ReactNativeJS")
        #expect(continuation?.pid == 4100)
        #expect(continuation?.level == "Error")
        #expect(continuation?.raw == "    at onPress (index.bundle:1:2)")
    }

    // MARK: Commands

    static let clock = #"echo "offsider-clock $(date +%s)"; "#

    @Test("history dumps from a start the device computes, live starts at the device's clock, each after the clock and marker lines")
    func scripts() {
        #expect(LogcatCommand.script(window: .last(.seconds(30)), source: .all)
            == Self.clock + #"echo offsider-logcat; logcat -d -v threadtime -v epoch -T "$(($(date +%s)-30)).000""#)
        #expect(LogcatCommand.script(window: .live(nil), source: .reactNative)
            == Self.clock + #"echo offsider-logcat; logcat -v threadtime -v epoch -T "$(date +%s).000" 'ReactNativeJS:V' 'ReactNative:V' '*:S'"#)
    }

    @Test("--since counts back from the device's own clock by how long ago it was on this Mac, so a skewed clock reads the same stretch")
    func sinceOnDeviceClock() {
        let now = Date(timeIntervalSince1970: 1_791_343_402.4)
        #expect(LogcatCommand.script(window: .since(now.addingTimeInterval(-90)), source: .all, now: now)
            == Self.clock + #"echo offsider-logcat; logcat -d -v threadtime -v epoch -T "$(($(date +%s)-90)).000""#)
        #expect(LogcatCommand.script(window: .since(now.addingTimeInterval(60)), source: .all, now: now).hasSuffix(#"-T "$(($(date +%s)-0)).000""#))
    }

    @Test("a device clock line far from this Mac's becomes one skew note, and a close one none")
    func skewNote() throws {
        let now = Date(timeIntervalSince1970: 1_791_343_402)
        var stream = LogcatStream(source: .all, serial: "R58TEST0001")
        _ = try stream.consume("offsider-clock 1791345202", now: now)
        #expect(stream.note == .clockSkew(seconds: 1800))
        var close = LogcatStream(source: .all, serial: "R58TEST0001")
        _ = try close.consume("offsider-clock 1791343404", now: now)
        #expect(close.note == nil)
    }

    @Test("--app looks up the pid in the same script, stopping with a marker when nothing runs, and filters on it")
    func appScript() {
        #expect(LogcatCommand.script(window: .last(.seconds(5)), source: .app("com.example.app"))
            == Self.clock + #"p=$(pidof -s 'com.example.app') || { echo offsider-not-running; exit 3; }; echo "offsider-pid $p"; echo offsider-logcat; logcat -d -v threadtime -v epoch -T "$(($(date +%s)-5)).000" --pid=$p"#)
    }

    @Test("--rn --app lists the package's user ID and reads every process with the uid column")
    func reactNativeAppScript() {
        #expect(LogcatCommand.script(window: .last(.seconds(120)), source: .reactNative(app: "com.example.app"))
            == Self.clock + #"cmd package list packages -U 'com.example.app'; echo offsider-logcat; logcat -d -v threadtime -v epoch -T "$(($(date +%s)-120)).000" -v uid"#)
    }

    @Test("--rn reads history with React Native filterspecs and parses the dump in one shell command")
    func reactNativeHistory() async throws {
        let server = Self.server()
        let entries = try await Self.read(LogQuery(source: .reactNative, window: .last(.seconds(30))), from: server)

        #expect(Self.shellCommands(server).count == 1)
        #expect(entries.map(\.tag) == ["ReactNativeJS", "ReactNativeJS", "ReactNative"])
    }

    @Test("--rn --app keeps React Native's tags and every line of the app's user ID, across a restart, and names the app's lines")
    func reactNativeAppHistory() async throws {
        let server = Self.server()
        let entries = try await Self.read(LogQuery(source: .reactNative(app: "com.example.app"), window: .last(.seconds(120))), from: server)

        #expect(Self.shellCommands(server).count == 1)
        #expect(entries.map(\.message) == ["tapped save", "[CONSOLE] Size Selected S", "after restart", "another app"])
        #expect(entries.map(\.process) == ["com.example.app", "com.example.app", "com.example.app", nil])
        #expect(entries.map(\.pid) == [4100, 4100, 5200, 6000])
    }

    @Test("--rn --app for a package that is not installed says so")
    func reactNativeAppNotInstalled() async throws {
        let server = Self.server(packages: "package:com.example.app.extra uid:10300\n")
        let error = await #expect(throws: AndroidError.self) {
            try await Self.read(LogQuery(source: .reactNative(app: "com.example.app"), window: .last(.seconds(5))), from: server)
        }
        #expect(error?.message == "com.example.app is not installed on emulator-5556. Install it, or drop --app to read React Native's log alone.")
    }

    @Test("the user ID is the exact package's, not one it prefixes", arguments: [
        ("package:com.example.app.extra uid:10300\npackage:com.example.app uid:10213", "10213"),
        ("package:com.example.app uid:10213 ", "10213"),
        ("package:com.example.apps uid:10300", nil),
    ] as [(String, String?)])
    func uidLookup(listing: String, uid: String?) {
        #expect(LogcatAppFilter.uid(of: "com.example.app", in: listing.components(separatedBy: "\n")) == uid)
    }

    @Test("--app reads the pid from the script's preamble and names the entries")
    func appHistory() async throws {
        let server = Self.server()
        let entries = try await Self.read(LogQuery(source: .app("com.example.app"), window: .last(.seconds(5))), from: server)

        #expect(Self.shellCommands(server).count == 1)
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.process == "com.example.app" })
    }

    @Test("--app fails clearly when the package is not running")
    func appNotRunning() async throws {
        let server = Self.server(pid: nil)
        let error = await #expect(throws: AndroidError.self) {
            try await Self.read(LogQuery(source: .app("com.example.app"), window: .last(.seconds(5))), from: server)
        }
        #expect(error?.message == "App com.example.app is not running on emulator-5556. Launch it, or drop --app to read all logs.")
    }

    @Test("--process uses the same pid lookup by process name")
    func processHistory() async throws {
        let server = Self.server(pid: nil)
        let error = await #expect(throws: AndroidError.self) {
            try await Self.read(LogQuery(source: .process("system_server"), window: .last(.seconds(5))), from: server)
        }
        #expect(error?.message == "Process system_server is not running on emulator-5556. Launch it, or drop --process to read all logs.")
        #expect(Self.shellCommands(server).count == 1)
    }

    @Test("--predicate is refused on Android without touching the device")
    func predicateRefused() async throws {
        let server = Self.server()
        let error = await #expect(throws: AndroidError.self) {
            try await Self.read(LogQuery(window: .last(.seconds(5)), predicate: "messageType == error"), from: server)
        }
        #expect(error?.message == "--predicate is iOS only; on Android use --app, --rn or --grep.")
        #expect(Self.shellCommands(server).isEmpty)
    }

    @Test("live output streams logcat until it exits or the window ends")
    func liveStream() async throws {
        let server = Self.server()
        let entries = try await Self.read(LogQuery(source: .reactNative, window: .live(.seconds(5))), from: server)

        #expect(Self.shellCommands(server) == [Self.clock + #"echo offsider-logcat; logcat -v threadtime -v epoch -T "$(date +%s).000" 'ReactNativeJS:V' 'ReactNative:V' '*:S'"#])
        #expect(entries.count == 3)
        #expect(server.closedStreams >= 1)
    }
}
