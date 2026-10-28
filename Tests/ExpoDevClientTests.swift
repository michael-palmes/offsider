import Foundation
@testable import Offsider
@testable import OffsiderAndroid
import OffsiderCore
import Testing

@Suite("Expo dev client preparing")
struct ExpoDevClientTests {
    @Test("bundle IDs and packages pass, shell metacharacters and bare names do not", arguments: [
        ("com.example.app", true),
        ("com.mpalmes.offsider.playground.rn", true),
        ("com.example.my-app", true),
        ("com.example.my_app", true),
        ("app", false),
        ("com.example;reboot", false),
        ("com.example app", false),
        ("com.example.$(id)", false),
    ])
    func validation(appID: String, valid: Bool) {
        let accepted = (try? ExpoDevClient.validate(appID: appID)) != nil
        #expect(accepted == valid)
    }

    @Test("iOS writes both keys to the app's own plist by path, not the device-wide domain")
    func iosWritesTheContainerPlist() {
        let writes = ExpoDevClient.iosDefaultsWriteArguments(udid: "UDID", dataContainer: "/data/Containers/X", bundleID: "com.example.app")
        let domain = "/data/Containers/X/Library/Preferences/com.example.app"
        #expect(writes == [
            ["simctl", "spawn", "UDID", "defaults", "write", domain, "EXDevMenuIsOnboardingFinished", "-bool", "YES"],
            ["simctl", "spawn", "UDID", "defaults", "write", domain, "EXDevMenuShowsAtLaunch", "-bool", "NO"],
        ])
    }

    @Test("iOS stops the app with simctl terminate before writing")
    func iosTerminates() {
        #expect(ExpoDevClient.iosTerminateArguments(udid: "UDID", bundleID: "com.example.app") == ["simctl", "terminate", "UDID", "com.example.app"])
    }

    @Test("iOS read-back needs the intro finished and the launch menu off")
    func iosConfirmation() {
        #expect(ExpoDevClient.iosDefaultsConfirmed("{\n    EXDevMenuIsOnboardingFinished = 1;\n    EXDevMenuShowsAtLaunch = 0;\n}\n"))
        #expect(!ExpoDevClient.iosDefaultsConfirmed("{\n    EXDevMenuIsOnboardingFinished = 1;\n    EXDevMenuShowsAtLaunch = 1;\n}\n"))
        #expect(!ExpoDevClient.iosDefaultsConfirmed("{\n    EXDevMenuShowsAtLaunch = 0;\n}\n"))
    }

    @Test("an iOS Release build and a plain React Native app are refused with what to install")
    func iosBundleClassification() {
        #expect(ExpoDevClient.iosBundleError(bundleID: "a.b", hasDevMenu: true, hasEmbeddedBundle: false) == nil)
        let release = ExpoDevClient.iosBundleError(bundleID: "a.b", hasDevMenu: false, hasEmbeddedBundle: true)
        #expect(release?.kind == .releaseBuild)
        #expect(release?.message.contains("Debug build") == true)
        #expect(ExpoDevClient.iosBundleError(bundleID: "a.b", hasDevMenu: false, hasEmbeddedBundle: false)?.kind == .notDevClient)
    }

    @Test("Android run-as refusals map to the build the user must install")
    func androidRunAsErrors() {
        #expect(ExpoDevClient.androidRunAsError(package: "a.b", output: "run-as: package not debuggable: a.b")?.kind == .notDebuggable)
        #expect(ExpoDevClient.androidRunAsError(package: "a.b", output: "run-as: unknown package: a.b")?.kind == .notInstalled)
        #expect(ExpoDevClient.androidRunAsError(package: "a.b", output: "sed: bad option") == nil)
    }

    @Test("Android install and dev client checks read pm path and dumpsys")
    func androidChecks() {
        #expect(ExpoDevClient.androidIsInstalled(pmPathOutput: "package:/data/app/~~x/a.b-1/base.apk\n"))
        #expect(!ExpoDevClient.androidIsInstalled(pmPathOutput: ""))
        #expect(ExpoDevClient.androidIsDevClient(packageDump: "  1a2b3c a.b/expo.modules.devlauncher.compose.AuthActivity filter"))
        #expect(!ExpoDevClient.androidIsDevClient(packageDump: "  1a2b3c a.b/.MainActivity filter"))
    }

    @Test("the Android script creates the preferences file when the app has none")
    func androidScriptCreates() throws {
        let sandbox = try ScriptSandbox()
        let output = try sandbox.run(ExpoDevClient.androidWriteCommand(package: "com.example.app"))
        #expect(ExpoDevClient.androidPrefsConfirmed(output))
        #expect(try sandbox.preferences() == ["isOnboardingFinished": "true", "showsAtLaunch": "false"])
    }

    @Test("the Android script replaces stale values and keeps the app's other preferences")
    func androidScriptMerges() throws {
        let sandbox = try ScriptSandbox()
        try sandbox.writePreferences("""
        <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
        <map>
            <boolean name="motionGestureEnabled" value="true" />
            <boolean name="isOnboardingFinished" value="false" />
            <boolean name="showsAtLaunch" value="true" />
        </map>
        """)
        _ = try sandbox.run(ExpoDevClient.androidWriteCommand(package: "com.example.app"))
        _ = try sandbox.run(ExpoDevClient.androidWriteCommand(package: "com.example.app"))
        #expect(try sandbox.preferences() == ["motionGestureEnabled": "true", "isOnboardingFinished": "true", "showsAtLaunch": "false"])
        let xml = try String(contentsOf: sandbox.preferencesURL, encoding: .utf8)
        #expect(xml.components(separatedBy: #"name="isOnboardingFinished""#).count == 2, "the key is written once")
    }

    @Test("the Android script fills an empty preferences map")
    func androidScriptFillsEmptyMap() throws {
        let sandbox = try ScriptSandbox()
        try sandbox.writePreferences("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map />\n")
        _ = try sandbox.run(ExpoDevClient.androidWriteCommand(package: "com.example.app"))
        #expect(try sandbox.preferences() == ["isOnboardingFinished": "true", "showsAtLaunch": "false"])
    }
}

/// Runs the device command with /bin/sh in a temporary app data directory, with `run-as` and toybox-style `sed -i` stand-ins.
private struct ScriptSandbox {
    let root: URL
    let bin: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("expo-dev-client-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Self.tool(at: bin.appendingPathComponent("run-as"), "#!/bin/sh\nshift\nexec \"$@\"\n")
        try Self.tool(at: bin.appendingPathComponent("sed"), "#!/bin/sh\nif [ \"$1\" = \"-i\" ]; then shift; exec /usr/bin/sed -i '' \"$@\"; fi\nexec /usr/bin/sed \"$@\"\n")
    }

    private static func tool(at url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var preferencesURL: URL { root.appendingPathComponent(ExpoDevClient.androidPreferencesFile) }

    func writePreferences(_ xml: String) throws {
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try xml.write(to: preferencesURL, atomically: true, encoding: .utf8)
    }

    func run(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = root
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ScriptFailure(output: output)
        }
        return output
    }

    /// Parses the file as Android's XmlUtils would see it: every `<boolean>` by name.
    func preferences() throws -> [String: String] {
        let collector = BooleanCollector()
        let parser = XMLParser(data: try Data(contentsOf: preferencesURL))
        parser.delegate = collector
        guard parser.parse() else {
            throw ScriptFailure(output: "invalid XML: \(String(describing: parser.parserError))")
        }
        return collector.values
    }
}

private struct ScriptFailure: Error, CustomStringConvertible {
    let output: String
    var description: String { output }
}

private final class BooleanCollector: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "boolean", let key = attributes["name"] {
            values[key] = attributes["value"]
        }
    }
}

@Suite("Expo dev client opening")
struct ExpoDevClientOpeningTests {
    @Test("the dev client link percent-encodes Metro's URL as expo start prints it")
    func link() {
        #expect(ExpoDevClient.devClientURL(scheme: "exp+offsiderplaygroundrn", host: "127.0.0.1", port: 8742)
            == "exp+offsiderplaygroundrn://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8742")
        #expect(ExpoDevClient.devClientURL(scheme: "exp+app", host: "10.0.2.2", port: 8081).hasSuffix("url=http%3A%2F%2F10.0.2.2%3A8081"))
    }

    @Test("exp+ schemes come from dumpsys package lines, once each, and from Info.plist URL types")
    func schemes() throws {
        let dump = """
              Scheme: "com.example.app"
              Scheme: "exp+offsiderplaygroundrn"
                Authority: "expo-development-client"
              Scheme: "exp+offsiderplaygroundrn"
        """
        #expect(ExpoDevClient.schemes(fromPackageDump: dump) == ["exp+offsiderplaygroundrn"])
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["myapp", "exp+myapp"]], ["CFBundleURLSchemes": ["com.example.app"]]],
        ], format: .xml, options: 0)
        #expect(ExpoDevClient.schemes(fromInfoPlist: plist) == ["exp+myapp"])
        #expect(throws: ExpoDevClientError.self) { try ExpoDevClient.singleScheme([], appID: "com.example.app") }
        #expect(throws: ExpoDevClientError.self) { try ExpoDevClient.singleScheme(["exp+a", "exp+b"], appID: "com.example.app") }
    }

    @Test("Android reaches Metro on loopback through an adb reverse, else the emulator's alias; a phone without one has no route")
    func androidHost() {
        #expect(ExpoDevClient.androidMetroHost(reverseList: "emulator-5554 tcp:8742 tcp:8742\n", port: 8742, isEmulator: true) == "127.0.0.1")
        #expect(ExpoDevClient.androidMetroHost(reverseList: "emulator-5554 tcp:8081 tcp:8081\n", port: 8742, isEmulator: true) == "10.0.2.2")
        #expect(ExpoDevClient.androidMetroHost(reverseList: "", port: 8742, isEmulator: false) == nil)
    }

    @Test("the launcher, a load error and the Bundling banner are read from the tree")
    func launcherStates() {
        func tree(_ labels: [String]) -> UITree {
            UITree(platform: .ios, device: "D", roots: [UINode(role: .application, native: .ios(IOSNativeAttributes()), children: labels.map {
                UINode(role: .text, label: $0, native: .ios(IOSNativeAttributes()))
            })])
        }
        #expect(ExpoDevLauncher.isLauncher(tree(["Development Build", "Searching for development servers..."])))
        #expect(ExpoDevLauncher.isLauncher(tree(["Development Build", "RECENTLY OPENED"])))
        #expect(!ExpoDevLauncher.isLauncher(tree(["Development Build"])))
        #expect(ExpoDevLauncher.loadError(in: tree(["There was a problem loading the project."])) != nil)
        #expect(ExpoDevLauncher.isLoading(tree(["Bundling 42%"])))
        #expect(!ExpoDevLauncher.isLoading(tree(["Home"])))
    }

    /// An Android dev client while its bundle loads: Expo's dev menu button inside unlabelled views, as a pixel_4 emulator lists it.
    static func devMenuOnly(plus extra: [UINode] = []) -> UITree {
        let button = FakeUI.node(.group, frame: FakeUI.frame(328, 69, 50, 90), platform: .android, children: [
            FakeUI.node(.image, label: "Tools", frame: FakeUI.frame(341, 80, 25, 25), platform: .android),
            FakeUI.node(.group, platform: .android, children: [FakeUI.node(.text, label: "Tools", frame: FakeUI.frame(341, 127, 25, 12), platform: .android)]),
        ])
        let compose = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 411, 923), platform: .android, children: [button] + extra)
        return FakeUI.tree(platform: .android, label: "OffsiderPlaygroundRN", [TapCoverTests.classed(compose, ExpoDevLauncher.composeHostClass)])
    }

    @Test("a tree is bare with no roots, an empty application or only Expo's dev menu button in it")
    func bare() {
        #expect(ExpoDevLauncher.isBare(UITree(platform: .android, device: "D", roots: [])))
        #expect(ExpoDevLauncher.isBare(FakeUI.tree([])))
        #expect(ExpoDevLauncher.isBare(Self.devMenuOnly()))
    }

    @Test("anything the app drew, even unlabelled views alone, is not bare")
    func notBare() {
        #expect(!ExpoDevLauncher.isBare(Self.devMenuOnly(plus: [FakeUI.node(.text, label: "Offsider Playground", platform: .android)])))
        #expect(!ExpoDevLauncher.isBare(Self.devMenuOnly(plus: [FakeUI.node(.group, id: "menu-title", platform: .android)])))
        #expect(!ExpoDevLauncher.isBare(FakeUI.tree([FakeUI.node(.group, children: [FakeUI.node(.other)])])))
    }

    @Test("Expo's dev menu button counts as bare wherever its Compose host sits in the window")
    func nestedHostIsBare() {
        let host = ExpoDevClientOpeningTests.devMenuOnly().roots[0].children[0]
        let content = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 411, 923), platform: .android, children: [host])
        #expect(ExpoDevLauncher.isBare(FakeUI.tree(platform: .android, label: "OffsiderPlaygroundRN", [content])))
    }

    @Test("an app's own Tools text outside Expo's Compose host is something the app drew")
    func toolsTextIsNotTheDevMenu() {
        let page = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 411, 923), platform: .android, children: [
            FakeUI.node(.text, label: "Tools", frame: FakeUI.frame(16, 120, 60, 20), platform: .android),
        ])
        #expect(!ExpoDevLauncher.isBare(FakeUI.tree(platform: .android, label: "OffsiderPlaygroundRN", [TapCoverTests.classed(page, "android.view.ViewGroup")])))
    }
}

@Suite("App liveness")
@MainActor
struct AppLivenessTests {
    static let bundleID = "com.example.app"

    static func tree(pid: Int?) -> UITree {
        UITree(platform: .ios, device: "D", roots: [UINode(role: .application, native: .ios(IOSNativeAttributes(pid: pid)))])
    }

    /// Records what the read looked at: bundle lookups, start reads and listings.
    final class Probe {
        var bundles: [Int: String] = [4100: AppLivenessTests.bundleID, 900: "com.apple.springboard"]
        var starts: [Int: UInt64] = [4100: 7, 900: 3]
        var listing: String?
        var bundleLookups: [Int] = []
        var startReads: [Int] = []
        var listings = 0

        func read(seen: AppProcess?, tree: UITree?, mayList: Bool) async -> AppLiveness {
            await SimulatorAppLiveness.read(
                AppLivenessTests.bundleID, seen: seen, tree: tree, mayList: mayList,
                bundleOf: { self.bundleLookups.append($0); return self.bundles[$0] },
                startOf: { self.startReads.append($0); return self.starts[$0] },
                listing: { self.listings += 1; return self.listing }
            )
        }
    }

    @Test("an iOS app is found by the tree's application pid, and once seen it costs one start read and no bundle lookup")
    func iosTreePidThenSysctl() async {
        let probe = Probe()
        #expect(await probe.read(seen: nil, tree: Self.tree(pid: 4100), mayList: true) == .running(AppProcess(pid: 4100, started: 7)))
        #expect(probe.listings == 0)

        let fresh = Probe()
        #expect(await fresh.read(seen: AppProcess(pid: 4100, started: 7), tree: Self.tree(pid: 900), mayList: true) == .running(AppProcess(pid: 4100, started: 7)))
        #expect(fresh.bundleLookups.isEmpty && fresh.startReads == [4100] && fresh.listings == 0)
    }

    @Test("a seen iOS process that is gone, or whose pid now has another start time, is not running; a new one for the bundle replaces it")
    func iosGoneOrReplaced() async {
        let gone = Probe()
        gone.starts[4100] = nil
        #expect(await gone.read(seen: AppProcess(pid: 4100, started: 7), tree: Self.tree(pid: 900), mayList: true) == .notRunning)

        let reused = Probe()
        reused.starts[4100] = 99
        #expect(await reused.read(seen: AppProcess(pid: 4100, started: 7), tree: nil, mayList: false) == .notRunning)

        let replaced = Probe()
        replaced.starts[4100] = nil
        replaced.bundles[4200] = Self.bundleID
        replaced.starts[4200] = 8
        #expect(await replaced.read(seen: AppProcess(pid: 4100, started: 7), tree: Self.tree(pid: 4200), mayList: false) == .running(AppProcess(pid: 4200, started: 8)))
    }

    @Test("before the iOS app is seen, launchctl runs when a listing is allowed and the tree is not the app's, as under SpringBoard's alert")
    func iosListingWithoutTheAppsTree() async {
        let probe = Probe()
        probe.listing = "PID\tStatus\tLabel\n4100\t0\tUIKitApplication:com.example.app[5f1e][rb-legacy]\n"
        #expect(await probe.read(seen: nil, tree: Self.tree(pid: 900), mayList: false) == .unknown)
        #expect(await probe.read(seen: nil, tree: Self.tree(pid: nil), mayList: false) == .unknown)
        #expect(probe.listings == 0)
        #expect(await probe.read(seen: nil, tree: Self.tree(pid: 900), mayList: true) == .running(AppProcess(pid: 4100, started: 7)))
        #expect(await probe.read(seen: nil, tree: Self.tree(pid: nil), mayList: true) == .running(AppProcess(pid: 4100, started: 7)))
        probe.listing = "PID\tStatus\tLabel\n-\t0\tUIKitApplication:com.example.app[5f1e][rb-legacy]\n"
        #expect(await probe.read(seen: nil, tree: nil, mayList: true) == .notRunning)
        #expect(probe.listings == 3)
    }

    @Test("pidof's one pid is running, an empty answer with status 1 is not, and anything else is unknown")
    func androidPidof() {
        #expect(AndroidBackend.liveness(pidofOutput: "4100\n", status: 0) == .running(AppProcess(pid: 4100)))
        #expect(AndroidBackend.liveness(pidofOutput: "", status: 1) == .notRunning)
        #expect(AndroidBackend.liveness(pidofOutput: "pidof: not found", status: 127) == .unknown)
    }

    @Test("Android reads liveness with one pidof over adb, and the crash cause from the crash buffer of the seen pid")
    func androidCommands() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang }
        ) { _, service in
            let command = String(service.dropFirst("shell,v2,raw:".count))
            if command.hasPrefix("pidof") { return FakeAdbServer.shell(stdout: "4100\n") }
            return FakeAdbServer.shell(stdout: "10-11 21:00:00.500  4100  4133 F libc    : Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 4133 (mqt_js), pid 4100 (com.example.app)\n")
        })
        let backend = AndroidBackend(host: AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)) { _, _ in }
        let device = DeviceID(rawValue: "emulator-5556", platform: .android)

        #expect(await backend.appLiveness(Self.bundleID, seen: nil, tree: nil, mayList: true, on: device) == .running(AppProcess(pid: 4100)))
        #expect(await backend.crashReport(Self.bundleID, process: AppProcess(pid: 4100), since: Date(), on: device) == .cause("signal 6 (SIGABRT)"))
        let commands = server.services.filter { $0.hasPrefix("shell,v2,raw:") }.map { String($0.dropFirst("shell,v2,raw:".count)) }
        #expect(commands == ["pidof -s 'com.example.app'", "logcat -b crash -d -v threadtime --pid=4100"])
    }

    @Test("the crash buffer gives a Java crash's exception class only, never its message")
    func javaCrashClassOnly() {
        let buffer = """
        --------- beginning of crash
        10-11 21:00:00.123  4100  4100 E AndroidRuntime: FATAL EXCEPTION: main
        10-11 21:00:00.123  4100  4100 E AndroidRuntime: Process: com.example.app, PID: 4100
        10-11 21:00:00.123  4100  4100 E AndroidRuntime: java.lang.IllegalStateException: someone@example.com token=abc
        10-11 21:00:00.123  4100  4100 E AndroidRuntime: \tat com.example.app.Screen.load(Screen.java:42)
        10-11 21:00:00.124  4100  4100 E AndroidRuntime: Caused by: java.io.IOException: more detail
        """
        let cause = CrashBufferParser.cause(in: buffer)
        #expect(cause == "java.lang.IllegalStateException")
        let message = RNOpen.crashed(Self.bundleID, process: AppProcess(pid: 4100), report: cause.map(AppCrashReport.cause), metro: "10.0.2.2:8742", device: DeviceID(rawValue: "emulator-5554", platform: .android)).userFacingDescription
        #expect(!message.contains("someone@example.com") && !message.contains("token") && !message.contains("abc"))
    }

    @Test("the crash buffer gives a native crash's signal, and nothing for a buffer with no crash")
    func nativeCrashSignal() {
        let buffer = """
        10-11 21:00:00.500  4100  4133 F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 4133 (mqt_js), pid 4100 (com.example.app)
        """
        #expect(CrashBufferParser.cause(in: buffer) == "signal 11 (SIGSEGV)")
        #expect(CrashBufferParser.cause(in: "--------- beginning of crash\n") == nil)
        #expect(CrashBufferParser.command(pid: 4100) == "logcat -b crash -d -v threadtime --pid=4100")
    }
}
