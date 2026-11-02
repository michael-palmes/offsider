import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// A device `sh` that runs the script with stand-ins for `run-as`, as Android's toybox would.
private struct PrefsDevice {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-prefs-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/shared_prefs"), withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("run-as")
        try "#!/bin/sh\nshift\ncd \"$OFFSIDER_APP_DATA\"\nexec \"$@\"\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }

    func write(_ name: String, _ bytes: String) throws {
        try bytes.write(to: root.appendingPathComponent("data/shared_prefs/\(name)"), atomically: true, encoding: .utf8)
    }

    func run(_ script: String) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "\(root.path)/bin:/usr/bin:/bin", "OFFSIDER_APP_DATA": "\(root.path)/data"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}

@Suite("Android app preference names")
@MainActor
struct AndroidAppPreferencesTests {
    static let package = "com.mpalmes.offsider.playground.rn"
    static let device = AndroidBackendTests.device
    static let secret = "PLANTED-SECRET-VALUE-7f3a9"

    /// Every place Android's writer puts a value, each planted with the secret.
    static let preferencesFile = """
    <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
    <map>
        <string name="auth_token">\(secret)</string>
        <string name="multi_line">first
    \(secret) second</string>
        <string name="looks_like_a_tag">&lt;string name=&quot;\(secret)&quot;&gt;x&lt;/string&gt;</string>
        <string name="quoted">he said &quot;\(secret)&quot; &amp; left</string>
        <int name="launch_count" value="314159" />
        <long name="updated_at" value="271828" />
        <float name="scale" value="1.5" />
        <boolean name="onboarded" value="true" />
        <set name="tags">
            <string>\(secret)</string>
        </set>
    </map>

    """

    @Test("the script run over a real file prints no value, so none crosses adb")
    func deviceFilterPrintsNoValue() throws {
        let device = try PrefsDevice()
        try device.write("app.xml", Self.preferencesFile)
        let result = try device.run(AndroidAppPackage.prefsScript(package: Self.package))
        for leak in [Self.secret, "314159", "271828", "1.5", "first", "second", "he said"] {
            #expect(!result.stdout.contains(leak), "\(leak)")
            #expect(!result.stderr.contains(leak), "\(leak)")
        }
        let preferences = try #require(AndroidAppPackage.preferences(result.stdout, package: Self.package))
        #expect(preferences.files.map(\.name) == ["app.xml"])
        #expect(preferences.files[0].keys == [
            .init(name: "auth_token", type: "string"), .init(name: "launch_count", type: "int"), .init(name: "looks_like_a_tag", type: "string"),
            .init(name: "multi_line", type: "string"), .init(name: "onboarded", type: "boolean"), .init(name: "quoted", type: "string"),
            .init(name: "scale", type: "float"), .init(name: "tags", type: "set"), .init(name: "updated_at", type: "long"),
        ])
    }

    @Test("no preference folder, an empty folder and a binary file each read plainly")
    func emptyAndBinary() throws {
        let device = try PrefsDevice()
        var result = try device.run(AndroidAppPackage.prefsScript(package: Self.package))
        #expect(AndroidAppPackage.preferences(result.stdout, package: Self.package)?.files == [])
        try device.write("binary.xml", "ABX\u{0}<string name=\"\(Self.secret)\"")
        result = try device.run(AndroidAppPackage.prefsScript(package: Self.package))
        let preferences = try #require(AndroidAppPackage.preferences(result.stdout, package: Self.package))
        #expect(preferences.files == [AppPreferenceFile(name: "binary.xml", keys: [], binary: true)])
        #expect(!result.stdout.contains(Self.secret))
    }

    @Test("a stray line holding a value is dropped, even if the device's filter failed")
    func strayLinesDropped() throws {
        let stdout = """
        offsider: file app.xml
        <string name="auth_token"
        <string name="auth_token">\(Self.secret)</string>
        \(Self.secret)
        <int name="count" value="\(Self.secret)"
        <secret name="\(Self.secret)"
        offsider: done
        """
        let preferences = try #require(AndroidAppPackage.preferences(stdout, package: Self.package))
        #expect(preferences.files == [AppPreferenceFile(name: "app.xml", keys: [.init(name: "auth_token", type: "string")])])
        #expect(!AppManagementReport.preferences(preferences, on: Self.device).contains(Self.secret))
    }

    @Test("a key name shaped like a token is masked and a very long one cut, as such a key is data")
    func dataShapedKeys() throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let long = String(repeating: "k", count: 500)
        let stdout = "offsider: file a.xml\n<string name=\"bearer \(jwt)\"\n<string name=\"\(long)\"\noffsider: done\n"
        let keys = try #require(AndroidAppPackage.preferences(stdout, package: Self.package)).files[0].keys
        #expect(!keys.contains { $0.name.contains(jwt) })
        #expect(keys.allSatisfy { $0.name.count <= AndroidAppPackage.maximumKeyCharacters + 1 })
    }

    @Test("XML escapes in a key name are decoded once, so a name reads as the app wrote it")
    func escapedNames() {
        #expect(AndroidAppPackage.preferenceKey(##"<string name="a&amp;b &quot;c&quot; &amp;lt;""##)?.name == #"a&b "c" &lt;"#)
    }

    static func backend(stdout: String = "", stderr: String = "", status: UInt8 = 0) throws -> (AndroidBackend, FakeAdbServer) {
        try AndroidAppLifecycleTests.setUp { _ in FakeAdbServer.shell(stdout: stdout, stderr: stderr, status: status) }
    }

    @Test("a release build's refusal names the fix and repeats nothing else the device said")
    func releaseRefusal() async throws {
        let (backend, _) = try Self.backend(stderr: "run-as: package not debuggable: \(Self.package)\n\(Self.secret)\n", status: 1)
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.appPreferences(Self.package, on: Self.device) }
        #expect(error?.kind == .notDebuggable)
        #expect(error?.message.contains("offsider app install") == true)
        #expect(error?.message.contains(Self.secret) == false)
    }

    @Test("any other failure says nothing the script printed, on stdout or stderr")
    func failureQuotesNoOutput() async throws {
        let (backend, _) = try Self.backend(stdout: "\(Self.secret)\n", stderr: "grep: \(Self.secret): denied\n", status: 2)
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.appPreferences(Self.package, on: Self.device) }
        #expect(error?.kind == .failed)
        #expect(error?.message.contains(Self.secret) == false)
    }

    @Test("an app that is not installed is app_not_installed")
    func notInstalled() async throws {
        let (backend, _) = try Self.backend(stderr: "run-as: unknown package: \(Self.package)\n", status: 1)
        let error = await #expect(throws: AndroidError.self) { try await backend.appPreferences(Self.package, on: Self.device) }
        #expect(error?.kind == .appNotInstalled)
    }

    @Test("the command reaches the app through run-as alone")
    func scriptNamesThePackageOnly() throws {
        let script = AndroidAppPackage.prefsScript(package: Self.package)
        #expect(script.hasPrefix("run-as '\(Self.package)' sh -c "))
        #expect(!script.contains("cat "))
    }
}

@Suite("Android app install and uninstall")
@MainActor
struct AndroidAppInstallTests {
    static let package = "com.example.fixture"
    static let device = AndroidBackendTests.device
    static let apk = ApkManifestTests.seeds.appendingPathComponent("deflated.apk")

    final class Sink: FakeServiceSession, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        let reply: String
        let closeAfter: Int?
        let answers: Bool

        init(reply: String = "Success\n", closeAfter: Int? = nil, answers: Bool = true) {
            self.reply = reply
            self.closeAfter = closeAfter
            self.answers = answers
        }

        var received: Data { lock.withLock { bytes } }
        func opened() -> Data { Data() }
        func closed() {}
        func pull() -> (bytes: Data, close: Bool)? { answers ? (Data(reply.utf8), true) : nil }
        var nextPull: ContinuousClock.Instant? { nil }
        func received(_ data: Data) -> (reply: Data, close: Bool) {
            lock.withLock { bytes.append(data) }
            if let closeAfter, received.count >= closeAfter { return (Data(), true) }
            return (Data(), false)
        }
    }

    static func setUp(installed: Bool = true, sink: Sink = Sink()) throws -> (AndroidBackend, FakeAdbServer) {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            [device.rawValue],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in
                if service.hasPrefix("exec:cmd package install") { return .session(sink) }
                return FakeAdbServer.shell(stdout: installed ? "offsider: stopped\n" : "offsider: not-installed\n")
            }
        ))
        return (try AndroidBackendTests.backend(server), server)
    }

    @Test("every byte of the file reaches the device, and Android is told the package it must declare")
    func streamsWithPackage() async throws {
        let sink = Sink()
        let (backend, server) = try Self.setUp(sink: sink)
        let file = try ApkFile(path: Self.apk.path)
        let install = try await backend.installApp(file, as: Self.package, on: Self.device)
        #expect(sink.received == (try Data(contentsOf: Self.apk)))
        #expect(install == AppInstall(app: Self.package, replaced: true, bytes: file.size, milliseconds: install.milliseconds))
        #expect(server.services.contains("exec:cmd package install -r -t -S \(file.size) --pkg \(Self.package)"))
    }

    @Test("a fresh install says it replaced nothing")
    func freshInstall() async throws {
        let (backend, _) = try Self.setUp(installed: false)
        #expect(try await backend.installApp(ApkFile(path: Self.apk.path), as: Self.package, on: Self.device).replaced == false)
    }

    @Test("Android's own package check comes back as package_mismatch", arguments: [
        "Failure [INSTALL_FAILED_INVALID_APK: android.content.pm.parsing.ApkLite@1 specified package a.b inconsistent with c.d]\n",
    ])
    func devicePackageCheck(reply: String) async throws {
        let (backend, _) = try Self.setUp(sink: Sink(reply: reply))
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.installApp(ApkFile(path: Self.apk.path), as: Self.package, on: Self.device) }
        #expect(error?.kind == .packageMismatch)
    }

    @Test("a signature clash names the uninstall that fixes it, and that it deletes data")
    func signatureClash() async throws {
        let (backend, _) = try Self.setUp(sink: Sink(reply: "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package signatures do not match]\n"))
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.installApp(ApkFile(path: Self.apk.path), as: Self.package, on: Self.device) }
        #expect(error?.kind == .installFailed)
        #expect(error?.message.contains("offsider app uninstall --app \(Self.package) --device \(Self.device.rawValue)") == true)
        #expect(error?.message.contains("deletes its data") == true)
    }

    /// Fails a write of the file's bytes, as a socket does when the phone drops off USB; smart-socket requests pass.
    struct DroppingStream: AdbByteStream {
        let inner: any AdbByteStream
        func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {
            if data.starts(with: [0x50, 0x4B]) { throw AdbConnectError.failed(errno: EPIPE) }
            try await inner.write(data, deadline: deadline)
        }
        func read(upTo count: Int, deadline: ContinuousClock.Instant) async throws -> Data { try await inner.read(upTo: count, deadline: deadline) }
        func close() async { await inner.close() }
    }

    struct DroppingConnector: AdbConnecting {
        let inner: any AdbConnecting
        func connect(to endpoint: LoopbackEndpoint, timeout: Duration) async throws -> any AdbByteStream {
            DroppingStream(inner: try await inner.connect(to: endpoint, timeout: timeout))
        }
    }

    @Test("a connection lost mid-file says nothing was installed and how to go on")
    func droppedMidFile() async throws {
        let sink = Sink(answers: false)
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            [Self.device.rawValue],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in service.hasPrefix("exec:") ? .session(sink) : FakeAdbServer.shell(stdout: "offsider: stopped\n") }
        ))
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        host.adbConnector = DroppingConnector(inner: server)
        let backend = AndroidBackend(host: host) { _, _ in }
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.installApp(ApkFile(path: Self.apk.path), as: Self.package, on: Self.device) }
        #expect(error?.kind == .installFailed)
        #expect(error?.message.contains("nothing was installed") == true)
        #expect(error?.message.contains("run the same command again") == true)
    }

    @Test("with the whole file sent and no answer, it never claims nothing was installed", arguments: [true, false])
    func noAnswerAfterWholeFile(closes: Bool) async throws {
        let (backend, _) = try Self.setUp(sink: Sink(closeAfter: closes ? 1 : nil, answers: false))
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.installApp(ApkFile(path: Self.apk.path), as: Self.package, on: Self.device) }
        #expect(error?.kind == .installFailed)
        #expect(error?.message.contains("nothing was installed") == false)
        #expect(error?.message.contains("offsider app info") == true)
    }

    @Test("the reply keeps only the failure code, as the rest may quote the APK")
    func replyCodeOnly() {
        #expect(AndroidAppPackage.installReply("Failure [INSTALL_FAILED_X: quoted words]\n") == .failure(code: "INSTALL_FAILED_X"))
        #expect(AndroidAppPackage.installReply("Success\n") == .success)
        #expect(AndroidAppPackage.installReply("Performing Streamed Install\n") == .unknown)
    }

    static func uninstall(_ stdout: String) async throws -> AppUninstall {
        let (backend, _) = try AndroidAppLifecycleTests.setUp { _ in FakeAdbServer.shell(stdout: stdout) }
        return try await backend.uninstallApp(package, on: device)
    }

    @Test("uninstall says whether there was anything to remove")
    func uninstall() async throws {
        #expect(try await Self.uninstall("offsider: stopped\nSuccess\n").wasInstalled)
        #expect(try await !Self.uninstall("offsider: not-installed\n").wasInstalled)
    }

    @Test("Android's refusal to remove an app fails plainly")
    func uninstallRefused() async throws {
        let error = await #expect(throws: AppLifecycleError.self) { try await Self.uninstall("offsider: stopped\nFailure [DELETE_FAILED_INTERNAL_ERROR]\n") }
        #expect(error?.message.contains("DELETE_FAILED_INTERNAL_ERROR") == true)
    }

    @Test("a cold launch reports TotalTime, WaitTime and LaunchState")
    func coldLaunchTimings() async throws {
        let stdout = "offsider: running\nStatus: ok\nLaunchState: COLD\nActivity: a/.B\nTotalTime: 641\nWaitTime: 656\nComplete\n"
        let (backend, server) = try AndroidAppLifecycleTests.setUp { _ in FakeAdbServer.shell(stdout: stdout) }
        let launch = try await backend.launchApp(Self.package, restart: true, on: Self.device)
        #expect(launch.milliseconds == 641 && launch.waitMilliseconds == 656 && launch.launchState == "COLD" && launch.start == .cold)
        #expect(AndroidAppLifecycleTests.shellCommands(server).contains { $0.contains("am force-stop") })
        let json = AppReport.launch(launch, action: "launch", on: Self.device)
        #expect(json.contains(#""milliseconds":641,"waitMilliseconds":656,"launchState":"COLD""#))
    }
}

@Suite("Android app broadcast")
@MainActor
struct AndroidAppBroadcastTests {
    static let package = "com.example.fixture"
    static let device = AndroidBackendTests.device
    static let action = "com.example.fixture.action.RELOAD"

    static func receiver(_ name: String, exported: Bool) -> String {
        """
        Receiver #0:
          ActivityInfo:
            name=\(name)
            packageName=\(package)
            enabled=true exported=\(exported) directBootAware=false
            ApplicationInfo:
              name=com.example.fixture.App
              enabled=true minSdkVersion=24 targetSdkVersion=36

        """
    }

    static func setUp(query: String, send: String = "Broadcast completed: result=42\n", dump: String = "") throws -> (AndroidBackend, FakeAdbServer) {
        try AndroidAppLifecycleTests.setUp { command in
            if command.hasPrefix("am broadcast") { return FakeAdbServer.shell(stdout: send) }
            if command.hasPrefix("dumpsys package") { return FakeAdbServer.shell(stdout: dump) }
            return FakeAdbServer.shell(stdout: "offsider: running\n" + query)
        }
    }

    static func sent(_ server: FakeAdbServer) -> [String] {
        AndroidAppLifecycleTests.shellCommands(server).filter { $0.hasPrefix("am broadcast") }
    }

    @Test("it goes to the app's package alone, stopped or not, and returns the receiver's result")
    func sendsToPackage() async throws {
        let (backend, server) = try Self.setUp(query: Self.receiver("com.example.fixture.Open", exported: true))
        let result = try await backend.sendBroadcast(Self.action, receiver: nil, to: Self.package, on: Self.device)
        #expect(result == AppBroadcast(app: Self.package, action: Self.action, receiver: nil, receivers: ["com.example.fixture.Open"], resultCode: 42))
        #expect(Self.sent(server) == ["am broadcast --include-stopped-packages -a '\(Self.action)' -p '\(Self.package)' 2>&1"])
    }

    @Test("a named receiver goes through -n inside the app's own package")
    func namedReceiver() async throws {
        let (backend, server) = try Self.setUp(query: Self.receiver("com.example.fixture.Open", exported: true))
        _ = try await backend.sendBroadcast(Self.action, receiver: ".Open", to: Self.package, on: Self.device)
        #expect(Self.sent(server) == ["am broadcast --include-stopped-packages -a '\(Self.action)' -n '\(Self.package)'/'.Open' 2>&1"])
    }

    @Test("a receiver the app lacks is refused, and nothing is sent")
    func missingReceiver() async throws {
        let (backend, server) = try Self.setUp(query: "No receivers found\n")
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.sendBroadcast(Self.action, receiver: ".None", to: Self.package, on: Self.device) }
        #expect(error?.kind == .receiverNotFound)
        #expect(Self.sent(server).isEmpty)
    }

    @Test("a receiver that is not exported is refused, as Android would drop it with no word, and nothing is sent")
    func notExported() async throws {
        let (backend, server) = try Self.setUp(query: Self.receiver("com.example.fixture.Closed", exported: false))
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.sendBroadcast(Self.action, receiver: nil, to: Self.package, on: Self.device) }
        #expect(error?.kind == .broadcastRefused)
        #expect(error?.message.contains("not exported") == true)
        #expect(Self.sent(server).isEmpty)
    }

    @Test("an action no manifest lists is still sent, for a receiver registered while the app runs")
    func runtimeReceiver() async throws {
        let (backend, server) = try Self.setUp(query: "No receivers found\n", send: "Broadcast completed: result=0\n")
        let result = try await backend.sendBroadcast("com.example.fixture.action.LIVE", receiver: nil, to: Self.package, on: Self.device)
        #expect(result.receivers.isEmpty && result.resultCode == 0)
        #expect(Self.sent(server).count == 1)
    }

    @Test("a protected action fails plainly and names the app's own actions", arguments: [
        "\nException occurred while executing 'broadcast':\njava.lang.SecurityException: Permission Denial: not allowed to send broadcast android.appwidget.action.APPWIDGET_UPDATE from unknown caller.\n",
        "Security exception: Permission Denial: not allowed to send broadcast android.intent.action.BOOT_COMPLETED from pid=1, uid=2000\n",
    ])
    func protectedAction(reply: String) async throws {
        let dump = """
        Receiver Resolver Table:
          Non-Data Actions:
              android.appwidget.action.APPWIDGET_UPDATE:
                1 \(Self.package)/.Widget filter 2
              \(Self.action):
                3 \(Self.package)/.Widget filter 4

        Packages:
          Package [\(Self.package)] (1):
        """
        let (backend, _) = try Self.setUp(query: "No receivers found\n", send: reply, dump: dump)
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.sendBroadcast("android.appwidget.action.APPWIDGET_UPDATE", receiver: nil, to: Self.package, on: Self.device) }
        #expect(error?.kind == .broadcastRefused)
        #expect(error?.message.contains("Nothing was sent") == true)
        #expect(error?.message.contains("Its own actions: \(Self.action).") == true)
    }

    @Test("a protected action a hidden receiver declares gets the protected refusal, not advice to export it")
    func protectedOverHiddenReceiver() async throws {
        let denied = "Security exception: Permission Denial: not allowed to send broadcast\n"
        let (backend, _) = try Self.setUp(query: Self.receiver("com.example.fixture.Widget", exported: false), send: denied)
        let error = await #expect(throws: AppLifecycleError.self) { try await backend.sendBroadcast("android.appwidget.action.APPWIDGET_UPDATE", receiver: nil, to: Self.package, on: Self.device) }
        #expect(error?.message.contains("for the system") == true)
        #expect(error?.message.contains("exported") == false)
    }

    @Test("an app that is not installed is app_not_installed, and nothing is sent")
    func notInstalled() async throws {
        let (backend, server) = try AndroidAppLifecycleTests.setUp { _ in FakeAdbServer.shell(stdout: "offsider: not-installed\n") }
        let error = await #expect(throws: AndroidError.self) { try await backend.sendBroadcast(Self.action, receiver: nil, to: Self.package, on: Self.device) }
        #expect(error?.kind == .appNotInstalled)
        #expect(Self.sent(server).isEmpty)
    }

    @Test("shell text in an action or receiver stops at validation", arguments: ["a b", "a;reboot", "a$(reboot)", "a'b", "-n", "a\nb", "a\n", ""])
    func validation(text: String) {
        #expect(throws: AppLifecycleError.self) { try AppBroadcastName.validate(action: text) }
        #expect(throws: AppLifecycleError.self) { try AppBroadcastName.validate(receiver: text) }
    }

    @Test("a receiver cannot name another app's component")
    func noOtherComponent() {
        #expect(throws: AppLifecycleError.self) { try AppBroadcastName.validate(receiver: "com.other/.Receiver") }
        #expect(throws: Never.self) { try AppBroadcastName.validate(receiver: ".Receiver") }
        #expect(throws: Never.self) { try AppBroadcastName.validate(receiver: "com.example.fixture.inner.Receiver$Nested") }
    }

    @Test("the receiver's own result text stays out, as only the code is kept")
    func resultCodeOnly() {
        #expect(AndroidAppPackage.broadcastReply(#"Broadcast completed: result=-1, data="anything""#) == .completed(resultCode: -1))
        #expect(AndroidAppPackage.broadcastReply(#"Broadcast completed: result=1, data="Permission Denial""#) == .completed(resultCode: 1))
        #expect(AndroidAppPackage.broadcastReply("no reply") == .unknown)
    }
}

@Suite("Android airplane mode")
@MainActor
struct AndroidAirplaneTests {
    static let emulator = DeviceID(rawValue: "emulator-5556", platform: .android)
    static let phone = DeviceID(rawValue: "R58MFAKE01", platform: .android)

    /// The setting as Android keeps it, with the commands that reach it.
    final class Radio: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        private var commands: [String] = []
        let refuses: Bool
        private let late: Bool
        private var landed = false

        init(on: Bool = false, refuses: Bool = false, late: Bool = false) {
            self.on = on
            self.refuses = refuses
            self.late = late
        }

        /// A change that was slow takes effect now; every later one is prompt.
        func land() {
            lock.withLock {
                on = true
                landed = true
            }
        }

        var isOn: Bool { lock.withLock { on } }
        var changes: [String] { lock.withLock { commands } }

        func reply(_ command: String) -> FakeAdbServer.Reply {
            lock.withLock {
                if command == AndroidAirplaneRecord.readScript { return FakeAdbServer.shell(stdout: on ? "1\n" : "0\n") }
                if command.hasPrefix("cmd connectivity airplane-mode ") {
                    commands.append(command)
                    if refuses { return FakeAdbServer.shell(stderr: "Unknown command\n", status: 1) }
                    if !late || landed { on = command.hasSuffix("enable") }
                }
                return FakeAdbServer.shell()
            }
        }
    }

    static func host(_ radio: Radio, serial: String, directory: URL) throws -> AndroidHost {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            [serial],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: "\(serial) device transport_id:2\n")
                default: return .hang
                }
            },
            device: { _, service in radio.reply(String(service.dropFirst("shell,v2,raw:".count))) }
        ))
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        host.airplaneRecordDirectory = { _ in directory.path }
        return host
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-airplane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test("what Offsider turned on, session stop turns off, once")
    func offsiderTurnedItOn() async throws {
        let radio = Radio()
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        let change = try await AndroidBackend(host: host) { _, _ in }.setAirplaneMode(true, on: Self.phone)
        #expect(change == AirplaneChange(previous: false, current: true, resetBySessionStop: true))
        #expect(radio.isOn)
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host, serial: Self.phone.rawValue).reset == [Self.phone.rawValue])
        #expect(!radio.isOn)
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host, serial: Self.phone.rawValue) == RecordResetOutcome())
    }

    @Test("what a person turned on stays on: session stop leaves it, and says nothing")
    func personTurnedItOn() async throws {
        let radio = Radio(on: true)
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        let change = try await AndroidBackend(host: host) { _, _ in }.setAirplaneMode(true, on: Self.phone)
        #expect(!change.resetBySessionStop)
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host, serial: Self.phone.rawValue) == RecordResetOutcome())
        #expect(radio.isOn)
        #expect(radio.changes.isEmpty)
    }

    @Test("a second on keeps Offsider's record, so session stop still resets it")
    func secondOn() async throws {
        let radio = Radio()
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        let backend = AndroidBackend(host: host) { _, _ in }
        _ = try await backend.setAirplaneMode(true, on: Self.phone)
        #expect(try await backend.setAirplaneMode(true, on: Self.phone).resetBySessionStop)
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host).reset.count == 1)
    }

    @Test("off clears the record, so a person turning it on later is not undone")
    func offClearsRecord() async throws {
        let radio = Radio()
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        let backend = AndroidBackend(host: host) { _, _ in }
        _ = try await backend.setAirplaneMode(true, on: Self.phone)
        _ = try await backend.setAirplaneMode(false, on: Self.phone)
        _ = radio.reply("cmd connectivity airplane-mode enable")
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host) == RecordResetOutcome())
        #expect(radio.isOn)
    }

    @Test("a person turning it off leaves the record to be dropped, with nothing sent")
    func personTurnedItOff() async throws {
        let radio = Radio()
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        _ = try await AndroidBackend(host: host) { _, _ in }.setAirplaneMode(true, on: Self.phone)
        _ = radio.reply("cmd connectivity airplane-mode disable")
        let before = radio.changes.count
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host) == RecordResetOutcome())
        #expect(radio.changes.count == before)
        #expect(AndroidAirplaneRecordStore(directory: directory.path).all().isEmpty)
    }

    @Test("a refusal leaves no record and says what to do")
    func refusal() async throws {
        let radio = Radio(refuses: true)
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        let error = await #expect(throws: AppLifecycleError.self) { try await AndroidBackend(host: host) { _, _ in }.setAirplaneMode(true, on: Self.phone) }
        #expect(error?.message.contains("Quick Settings") == true)
        #expect(AndroidAirplaneRecordStore(directory: directory.path).all().isEmpty)
    }

    @Test("a change that lands after the wait keeps the record, so session stop still undoes it")
    func lateChange() async throws {
        let radio = Radio(late: true)
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        await #expect(throws: AppLifecycleError.self) { try await AndroidBackend(host: host) { _, _ in }.setAirplaneMode(true, on: Self.phone) }
        radio.land()
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host).reset == [Self.phone.rawValue])
        #expect(!radio.isOn)
    }

    @Test("with no private folder it stays off rather than leave a change nothing can undo")
    func noFolder() async throws {
        let radio = Radio()
        var host = try Self.host(radio, serial: Self.phone.rawValue, directory: try Self.directory())
        host.airplaneRecordDirectory = { _ in nil }
        await #expect(throws: AppLifecycleError.self) { try await AndroidBackend(host: host) { _, _ in }.setAirplaneMode(true, on: Self.phone) }
        #expect(!radio.isOn)
        #expect(radio.changes.isEmpty)
    }

    @Test("a reset that does not land keeps the record and reports failed, so the stop can name it")
    func resetThatFails() async throws {
        let radio = Radio(on: true, late: true)
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        let store = AndroidAirplaneRecordStore(directory: directory.path)
        try store.save(AndroidAirplaneRecord(serial: Self.phone.rawValue, avd: nil))
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host) == RecordResetOutcome(failed: [Self.phone.rawValue]))
        #expect(store.load(serial: Self.phone.rawValue) != nil)
    }

    @Test("an unplugged phone keeps its record and is reported, until a month has passed")
    func unpluggedPhone() async throws {
        let directory = try Self.directory()
        let host = try Self.host(Radio(on: true), serial: "OTHERPHONE1", directory: directory)
        let store = AndroidAirplaneRecordStore(directory: directory.path)
        try store.save(AndroidAirplaneRecord(serial: Self.phone.rawValue, avd: nil))
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host) == RecordResetOutcome(notConnected: [Self.phone.rawValue]))
        #expect(store.load(serial: Self.phone.rawValue) != nil)

        let old = Date(timeIntervalSinceNow: -AndroidAirplaneRecordStore.forgottenAfter - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.appendingPathComponent(AndroidPostureRecord.fileName(serial: Self.phone.rawValue)).path)
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host) == RecordResetOutcome())
        #expect(store.load(serial: Self.phone.rawValue) == nil)
    }

    @Test("a phone no longer allowed is left alone on an unnamed stop")
    func unpermittedLeftAlone() async throws {
        let radio = Radio(on: true)
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        try AndroidAirplaneRecordStore(directory: directory.path).save(AndroidAirplaneRecord(serial: Self.phone.rawValue, avd: nil))
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host, permits: { _ in false }) == RecordResetOutcome(skipped: [Self.phone.rawValue]))
        #expect(radio.isOn)
    }

    @Test("another AVD on the same serial is left alone, and the record waits for its own")
    func anotherAVD() async throws {
        let radio = Radio(on: true)
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.emulator.rawValue, directory: directory)
        let store = AndroidAirplaneRecordStore(directory: directory.path)
        try store.save(AndroidAirplaneRecord(serial: Self.emulator.rawValue, avd: "Someone_Elses_AVD"))
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host, serial: Self.emulator.rawValue) == RecordResetOutcome(notConnected: [Self.emulator.rawValue]))
        #expect(radio.isOn)
        #expect(store.load(serial: Self.emulator.rawValue) != nil)
    }

    @Test("a named stop finds a phone's record by serial, and leaves another device's")
    func namedStop() async throws {
        let radio = Radio(on: true)
        let directory = try Self.directory()
        let host = try Self.host(radio, serial: Self.phone.rawValue, directory: directory)
        let store = AndroidAirplaneRecordStore(directory: directory.path)
        try store.save(AndroidAirplaneRecord(serial: Self.phone.rawValue, avd: nil))
        try store.save(AndroidAirplaneRecord(serial: "OTHERPHONE1", avd: nil))
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host, serial: "OTHERPHONE2") == RecordResetOutcome())
        #expect(await AndroidBackend.resetRecordedAirplaneModes(host: host, serial: Self.phone.rawValue).reset == [Self.phone.rawValue])
        #expect(store.load(serial: "OTHERPHONE1") != nil)
    }

    @Test("an unreadable record is dropped, and a record never names another device")
    func recordRoundTrip() throws {
        let directory = try Self.directory()
        let store = AndroidAirplaneRecordStore(directory: directory.path)
        let record = AndroidAirplaneRecord(serial: "a", avd: "b")
        #expect(AndroidAirplaneRecord(data: record.encoded()) == record)
        try store.save(record)
        #expect(store.load(serial: "a") == record)
        #expect(store.load(serial: "other") == nil)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(AndroidPostureRecord.fileName(serial: "a")))
        #expect(store.load(serial: "a") == nil)
    }

    @Test("the setting reads as Android prints it")
    func parseSetting() {
        #expect(AndroidAirplaneRecord.parseSetting("1\n") == true)
        #expect(AndroidAirplaneRecord.parseSetting("0\n") == false)
        #expect(AndroidAirplaneRecord.parseSetting("null\n") == false)
        #expect(AndroidAirplaneRecord.parseSetting("oops") == nil)
    }
}
