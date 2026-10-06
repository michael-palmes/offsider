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

    /// Records every shell command; `pidof` answers with `pid` (or fails), `logcat -d` with `dump`, and live `logcat` streams `dump` then exits.
    static func server(pid: String? = "4100") -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang }
        ) { _, service in
            let command = String(service.dropFirst("shell,v2,raw:".count))
            if command.hasPrefix("pidof") {
                return pid.map { FakeAdbServer.shell(stdout: "\($0)\n") } ?? FakeAdbServer.shell(status: 1)
            }
            return FakeAdbServer.shell(stdout: dump)
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

    @Test("history dumps from a start the device computes, live starts at the device's clock")
    func scripts() {
        #expect(LogcatCommand.script(window: .last(.seconds(30)), pid: nil, reactNative: false)
            == #"logcat -d -v threadtime -v epoch -T "$(($(date +%s)-30)).000""#)
        #expect(LogcatCommand.script(window: .since(Date(timeIntervalSince1970: 1_790_945_238.25)), pid: 4100, reactNative: false)
            == "logcat -d -v threadtime -v epoch -T '1790945238.250' --pid=4100")
        #expect(LogcatCommand.script(window: .live(nil), pid: nil, reactNative: true)
            == #"logcat -v threadtime -v epoch -T "$(date +%s).000" 'ReactNativeJS:V' 'ReactNative:V' '*:S'"#)
    }

    @Test("--rn reads history with React Native filterspecs and parses the dump")
    func reactNativeHistory() async throws {
        let server = Self.server()
        let entries = try await Self.read(LogQuery(source: .reactNative, window: .last(.seconds(30))), from: server)

        #expect(Self.shellCommands(server) == [#"logcat -d -v threadtime -v epoch -T "$(($(date +%s)-30)).000" 'ReactNativeJS:V' 'ReactNative:V' '*:S'"#])
        #expect(entries.map(\.tag) == ["ReactNativeJS", "ReactNativeJS", "ReactNative"])
    }

    @Test("--app looks up the package's pid first, filters on it and names the entries")
    func appHistory() async throws {
        let server = Self.server()
        let entries = try await Self.read(LogQuery(source: .app("com.example.app"), window: .last(.seconds(5))), from: server)

        #expect(Self.shellCommands(server) == [
            "pidof -s 'com.example.app'",
            #"logcat -d -v threadtime -v epoch -T "$(($(date +%s)-5)).000" --pid=4100"#,
        ])
        #expect(entries.allSatisfy { $0.process == "com.example.app" })
    }

    @Test("--app fails clearly when the package is not running, before reading logcat")
    func appNotRunning() async throws {
        let server = Self.server(pid: nil)
        let error = await #expect(throws: AndroidError.self) {
            try await Self.read(LogQuery(source: .app("com.example.app"), window: .last(.seconds(5))), from: server)
        }
        #expect(error?.message == "App com.example.app is not running on emulator-5556. Launch it, or drop --app to read all logs.")
        #expect(!Self.shellCommands(server).contains { $0.hasPrefix("logcat") })
    }

    @Test("--process uses the same pid lookup by process name")
    func processHistory() async throws {
        let server = Self.server(pid: nil)
        let error = await #expect(throws: AndroidError.self) {
            try await Self.read(LogQuery(source: .process("system_server"), window: .last(.seconds(5))), from: server)
        }
        #expect(error?.message == "Process system_server is not running on emulator-5556. Launch it, or drop --process to read all logs.")
        #expect(Self.shellCommands(server) == ["pidof -s 'system_server'"])
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

        #expect(Self.shellCommands(server) == [#"logcat -v threadtime -v epoch -T "$(date +%s).000" 'ReactNativeJS:V' 'ReactNative:V' '*:S'"#])
        #expect(entries.count == 3)
        #expect(server.closedStreams >= 1)
    }
}
