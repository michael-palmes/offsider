import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("app install, uninstall, prefs, broadcast and airplane")
@MainActor
struct AppManagementCommandTests {
    static let pixel = AppArgumentTests.pixel
    static let pinned = "com.example.pinned"

    static func route(_ allowance: DeviceAllowance?) -> DeviceRouter.Route {
        DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: []), device: allowance == nil ? DeviceID(rawValue: "emulator-5554", platform: .android) : pixel, allowance: allowance)
    }

    static func allowance(apps: [String], testDevice: Bool = false) -> DeviceAllowance {
        DeviceAllowance(platform: .android, key: pixel.rawValue, name: "Test Pixel", added: Date(), expires: nil, apps: apps, testDevice: testDevice)
    }

    @Test("install and uninstall refuse an app reached only through any app, as they change its data")
    func anyAppIsNotEnough() {
        let any = Self.allowance(apps: [DeviceAllowance.wholeDevicePin])
        let error = #expect(throws: CLIError.self) {
            try AppTarget.requirePinned("com.example.other", route: Self.route(any), command: "uninstall", gate: AppArgumentTests.gate(any))
        }
        #expect(error?.reason == .appNotAllowed)
        #expect(error?.errorDescription?.contains("Nothing was sent") == true)
    }

    @Test("a pinned app, a test device and an emulator pass")
    func pinnedPasses() throws {
        let pin = Self.allowance(apps: [Self.pinned])
        try AppTarget.requirePinned(Self.pinned, route: Self.route(pin), command: "install", gate: AppArgumentTests.gate(pin))
        let whole = Self.allowance(apps: [DeviceAllowance.wholeDevicePin], testDevice: true)
        try AppTarget.requirePinned("com.example.other", route: Self.route(whole), command: "install", gate: AppArgumentTests.gate(whole))
        try AppTarget.requirePinned("com.example.other", route: Self.route(nil), command: "install", gate: AppArgumentTests.gate(pin))
    }

    @Test("a test device that managed policy turns off is back to needing the pin")
    func managedTestDevice() {
        let whole = Self.allowance(apps: [DeviceAllowance.wholeDevicePin], testDevice: true)
        let gate = DevicePolicyGate.fixed(PhysicalDevicePolicy(managed: ManagedDevicePolicy(allowTestDevices: false), list: DeviceAllowList(entries: [whole])))
        #expect(throws: CLIError.self) { try AppTarget.requirePinned("com.example.other", route: Self.route(whole), command: "install", gate: gate) }
    }

    @Test("an app another command would refuse is refused for these too, on a phone")
    func deniedApp() {
        let any = Self.allowance(apps: [DeviceAllowance.wholeDevicePin])
        let error = #expect(throws: CLIError.self) {
            _ = try AppTarget.resolve(.named("com.android.settings"), route: Self.route(any), command: "prefs", gate: AppArgumentTests.gate(any), profile: { nil })
        }
        #expect(error?.reason == .appNotAllowed)
    }

    @Test("install's app defaults to the APK's own where that is allowed, and otherwise never guesses")
    func installTarget() throws {
        let declared = "com.example.declared"
        #expect(try AppManagementSupport.installTarget(.named(nil), declared: declared, route: Self.route(nil)) == declared)
        #expect(try AppManagementSupport.installTarget(.named("com.example.named"), declared: declared, route: Self.route(nil)) == "com.example.named")
        let two = Self.allowance(apps: [declared, Self.pinned])
        #expect(try AppManagementSupport.installTarget(.named(nil), declared: declared, route: Self.route(two), gate: AppArgumentTests.gate(two)) == declared)
        let one = Self.allowance(apps: [Self.pinned])
        #expect(try AppManagementSupport.installTarget(.named(nil), declared: declared, route: Self.route(one), gate: AppArgumentTests.gate(one)) == Self.pinned)
    }

    @Test("no option asks prefs for a value, a length or a hash")
    func prefsHasNoValueOption() {
        let help = AppPrefsCommand.helpMessage(columns: 200)
        let options = help.matches(of: #/--([a-z-]+)/#).map { String($0.1) }
        #expect(!options.contains { ["value", "values", "length", "hash", "show", "raw", "no-redact"].contains($0) })
        #expect(throws: (any Error).self) { try OffsiderCommand.parseAsRoot(["app", "prefs", "--value", "--device", "emulator-5554"]) }
    }

    @Test("prefs is a read that leaves the tree cache alone and a line in a run; the others count as input")
    func effects() {
        #expect(CommandEffect.of("app prefs") == .none)
        #expect(EvidenceRecorder.records("app prefs"))
        for command in ["app install", "app uninstall", "app broadcast", "airplane"] {
            #expect(CommandEffect.table[command] == .input, "\(command)")
        }
    }

    @Test("prefs output holds names and types in every view, for a person and an agent")
    func prefsViews() {
        let preferences = AppPreferences(app: "com.example.app", files: [
            AppPreferenceFile(name: "app.xml", keys: [.init(name: "auth_token", type: "string")]),
            AppPreferenceFile(name: "binary.xml", keys: [], binary: true),
        ])
        let lines = AppPrefsCommand.lines(preferences)
        #expect(lines.contains("2 files, 1 key (names and types only)"))
        #expect(lines.contains("auth_token") && lines.contains("string") && lines.contains("binary, keys not listed"))
        let json = AppManagementReport.preferences(preferences, on: Self.pixel)
        #expect(json.contains(#""untrusted":["files[].name","files[].keys[].name"]"#))
        #expect(AppPrefsCommand.lines(AppPreferences(app: "com.example.app", files: [])) == "com.example.app has no preference files.")
    }

    @Test("AsyncStorage key names list beside the preference files in every view, with nothing but names")
    func asyncStorageViews() {
        let file = AppPreferenceFile(name: "app.xml", keys: [.init(name: "auth_token", type: "string")])
        let store = AppKeyStore(database: "RKStorage", keys: ["offsider-fixture-profile", "offsider-fixture-theme"])
        let preferences = AppPreferences(app: "com.example.app", files: [file], asyncStorage: store)
        let lines = AppPrefsCommand.lines(preferences)
        #expect(lines.contains("1 file, 1 key, 2 AsyncStorage keys (names and types only)"))
        #expect(lines.contains("  AsyncStorage (RKStorage)  2 keys\n") && lines.contains("offsider-fixture-profile") && lines.contains("offsider-fixture-theme"))
        let json = AppManagementReport.preferences(preferences, on: Self.pixel)
        #expect(json.contains(#""asyncStorage":{"database":"RKStorage","keys":["offsider-fixture-profile","offsider-fixture-theme"],"cut":0}"#))
        #expect(json.contains(#""untrusted":["files[].name","files[].keys[].name","asyncStorage.keys[]"]"#))
        #expect(AppPrefsCommand.notices(preferences, on: Self.pixel).isEmpty)

        let alone = AppPreferences(app: "com.example.app", files: [], asyncStorage: store)
        #expect(AppPrefsCommand.lines(alone).contains("0 files, 0 keys, 2 AsyncStorage keys"))
        #expect(AppManagementReport.preferences(AppPreferences(app: "com.example.app", files: [file]), on: Self.pixel).contains(#""asyncStorage":null"#))
    }

    @Test("a database left unread says why in one word, lists no key, and names the fix where there is one")
    func asyncStorageUnread() {
        let changing = AppPreferences(app: "com.example.app", files: [], asyncStorage: AppKeyStore(database: "RKStorage", keys: [], unread: .changing))
        #expect(AppPrefsCommand.lines(changing).contains("0 files, 0 keys (names and types only)\n  AsyncStorage (RKStorage)  not read (changing)"))
        #expect(AppManagementReport.preferences(changing, on: Self.pixel).contains(#""asyncStorage":{"database":"RKStorage","keys":[],"cut":0,"unread":"changing"}"#))
        let notices = AppPrefsCommand.notices(changing, on: Self.pixel)
        #expect(notices.map(\.command) == ["offsider app stop --app com.example.app --device \(Self.pixel.rawValue)"])

        for word in AppKeyStore.Unread.allCases {
            let unread = AppPreferences(app: "com.example.app", files: [], asyncStorage: AppKeyStore(database: "AsyncStorage", keys: [], unread: word))
            let notice = AppPrefsCommand.notices(unread, on: Self.pixel)
            #expect(notice.count == 1 && notice[0].text.contains("AsyncStorage") && notice[0].text.contains("not listed"), "\(word)")
            #expect(AppManagementReport.preferences(unread, on: Self.pixel).contains(#""unread":"\#(word.rawValue)""#), "\(word)")
        }
        let failed = AppPrefsCommand.notices(AppPreferences(app: "com.example.app", files: [], asyncStorage: AppKeyStore(database: "RKStorage", keys: [], unread: .failed)), on: Self.pixel)
        #expect(failed[0].text.contains("did not answer") && !failed[0].text.contains("SQLite"))

        let both = AppPreferences(app: "com.example.app", files: [], asyncStorage: AppKeyStore(database: "AsyncStorage", keys: ["a…"], cut: 1, other: "RKStorage"))
        let texts = AppPrefsCommand.notices(both, on: Self.pixel).map(\.text)
        #expect(texts.count == 2 && texts[0].contains("RKStorage") && texts[1].contains("1 key name"))
    }

    @Test("a simulator or an iPhone is told these are Android only, before any stack starts")
    func androidOnly() {
        let simulator = #expect(throws: CLIError.self) { try AppManagementSupport.requireAndroid("00000000-0000-0000-0000-000000000001", command: "app prefs") }
        #expect(simulator?.reason == .notSupported)
        #expect(simulator?.errorDescription?.contains("app prefs is Android only") == true)
        #expect(simulator?.errorDescription?.contains("sleep") == false)
    }

    @Test("--cold is another name for --restart")
    func coldFlag() throws {
        let command = try #require(try OffsiderCommand.parseAsRoot(["app", "launch", "--cold", "--app", "com.example.app", "--device", "emulator-5554"]) as? AppLaunchCommand)
        #expect(command.restart)
    }

    @Test("airplane's on says session stop resets it; set by hand, it says the stop leaves it")
    func airplaneNotices() {
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        let ours = AirplaneCommand.notices(AirplaneChange(previous: false, current: true, resetBySessionStop: true), set: true, on: device)
        #expect(ours.count == 1)
        let theirs = AirplaneCommand.notices(AirplaneChange(previous: true, current: true, resetBySessionStop: false), set: true, on: device)
        #expect(theirs.count == 1)
        #expect(AirplaneCommand.notices(AirplaneChange(previous: true, current: false, resetBySessionStop: false), set: true, on: device).isEmpty)
    }

    @Test("airplane takes on, off or nothing")
    func airplaneValues() throws {
        #expect(try AirplaneCommand.parse(["on", "--device", "emulator-5554"]).target() == true)
        #expect(try AirplaneCommand.parse(["off", "--device", "emulator-5554"]).target() == false)
        #expect(try AirplaneCommand.parse(["--device", "emulator-5554"]).target() == nil)
        #expect(throws: (any Error).self) { try AirplaneCommand.parse(["maybe", "--device", "emulator-5554"]) }
    }

    @Test("session stop's line and JSON name the airplane mode it turned off")
    func sessionStopReports() {
        let stopped = DeviceSessionRow.stopped(runners: [], brokers: [], airplanes: ["emulator-5554"])
        #expect(stopped.first?.parts == ["airplane mode"])
        #expect(DeviceSessionRow.stoppedJSON(stopped).contains(#""airplane":true"#))
    }

    @Test("an APK file that is not one is refused before any device is named")
    func notAnApk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-\(UUID().uuidString).apk")
        try Data("plain text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AppManagementSupport.open(url.path)
        let error = #expect(throws: AppLifecycleError.self) { try AppManagementSupport.package(of: file) }
        #expect(error?.kind == .apkUnreadable)
    }

    @Test("rules can allow each new command once, none of Offsider's own rules catches them, and --print-rules lists them")
    func allowOnceRules() {
        #expect(AgentPermissionRules.allowOnceClaude == [
            "Bash(offsider app install*)", "Bash(offsider app uninstall*)", "Bash(offsider app prefs*)", "Bash(offsider app broadcast*)", "Bash(offsider airplane*)",
        ])
        for rule in AgentPermissionRules.rules {
            #expect(!rule.claude.hasPrefix("offsider app") && !rule.claude.hasPrefix("offsider airplane"), "\(rule.claude)")
        }
        let printed = AgentPermissionRules.printedJSON()
        #expect(printed.contains("allowOnce") && printed.contains("offsider app prefs*"))
        #expect(AgentPermissionRules.allowOnceCodex.allSatisfy { $0.contains(#"decision="allow""#) })
    }
}
