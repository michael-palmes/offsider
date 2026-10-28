import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

@Suite("App commands")
struct AppCommandTests {
    static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)
    static let phone = DeviceID(rawValue: PolicyFixtures.serial, platform: .android)

    @Test("links keep & ? ; and percent escapes, and need a scheme", arguments: [
        "https://example.com/offer?id=7&ref=push",
        "offsiderplaygroundrn://screen/rows-test",
        "myapp+dev://a;b=%20c",
    ])
    func linksAccepted(_ link: String) throws {
        #expect(try AppLink.validate(link) == link)
    }

    @Test("links that reach other apps, files or code, or hide characters, are refused", arguments: [
        "intent://x#Intent;component=com.example/.Evil;end",
        "INTENT:#Intent;end",
        "file:///sdcard/a.html",
        "content://com.example.provider/secret",
        "javascript:alert(1)",
        "data:text/html,<b>x</b>",
        "https://example.com/a b",
        "https://example.com/\u{202E}gpj",
        "https://example.com/\n",
        "no-scheme-here",
        "1http://example.com",
        "",
    ])
    func linksRefused(_ link: String) {
        #expect(throws: AppLifecycleError.self) { try AppLink.validate(link) }
    }

    @Test("a link over 4 KiB is refused")
    func longLinkRefused() {
        #expect(throws: AppLifecycleError.self) { try AppLink.validate("https://example.com/" + String(repeating: "a", count: 4_100)) }
    }

    @Test("app open refuses a refused scheme as a usage error before any device is reached")
    func openRefusesSchemeAtParse() async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("app open 'intent://x#Intent;end' --app com.example.app --device emulator-5554")
        #expect(result.exitCode == 64)
        #expect(result.output.contains("intent: links are refused"))
    }

    @Test("info JSON names every field, nulls what the platform did not say, and marks the app's own text untrusted")
    func infoJSON() throws {
        let info = AppInfo(app: "com.example.app", name: "Example", version: "2.1", build: "40", installer: "com.android.vending", firstInstalled: PolicyFixtures.added, debuggable: false)
        let json = AppReport.info(info, on: Self.phone)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["action"] as? String == "info")
        #expect(object["version"] as? Int == 1)
        #expect(object["appVersion"] as? String == "2.1")
        #expect(object["build"] as? String == "40")
        #expect(object["firstInstalled"] as? String == ProcessStamp.timestamp(PolicyFixtures.added))
        #expect(object["lastUpdated"] is NSNull)
        #expect(object["notifications"] is NSNull)
        #expect(object["debuggable"] as? Bool == false)
        #expect(object["untrusted"] as? [String] == ["name", "appVersion", "build", "installer"])
    }

    @Test("launch and open JSON carry the start, restart, time and the link sent")
    func launchJSON() throws {
        let launch = AppLaunch(app: "com.example.app", start: .cold, restarted: true, milliseconds: 412)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(AppReport.launch(launch, action: "open", url: "myapp://a?b=1&c=2", on: Self.phone).utf8)) as? [String: Any])
        #expect(object["url"] as? String == "myapp://a?b=1&c=2")
        #expect(object["start"] as? String == "cold")
        #expect(object["restarted"] as? Bool == true)
        #expect(object["milliseconds"] as? Int == 412)
        #expect(object["pid"] is NSNull)
    }

    // MARK: Simulators

    /// `simctl appinfo`'s output for an app, trimmed.
    static let simctlAppInfo = """
    {
        ApplicationType = User;
        CFBundleDisplayName = "Offsider Playground";
        CFBundleExecutable = OffsiderPlayground;
        CFBundleIdentifier = "com.mpalmes.offsider.playground";
        CFBundleName = OffsiderPlayground;
        CFBundleShortVersionString = "1.0";
        CFBundleVersion = 12;
        GroupContainers =     {
        };
        IsDeveloperApp = 1;
    }
    """

    @Test("simctl appinfo gives the display name, version and build")
    func simulatorInfo() throws {
        let info = try #require(SimulatorApps.info(Self.simctlAppInfo, bundleID: "com.mpalmes.offsider.playground"))
        #expect(info == AppInfo(app: "com.mpalmes.offsider.playground", name: "Offsider Playground", version: "1.0", build: "12"))
        #expect(SimulatorApps.info(Self.simctlAppInfo, bundleID: "com.example.other") == nil)
        #expect(SimulatorApps.info(Self.simctlAppInfo, bundleID: "com.mpalmes.Offsider.Playground")?.version == "1.0")
    }

    @Test("launchctl list finds only the app's own running process")
    func simulatorRunningPID() {
        let list = """
        PID\tStatus\tLabel
        63398\t0\tUIKitApplication:com.apple.Spotlight[41a2][rb-legacy]
        -\t0\tUIKitApplication:com.example.app.widget[1a2b][rb-legacy]
        63513\t0\tUIKitApplication:com.example.app[58a4][rb-legacy]
        """
        #expect(SimulatorApps.runningPID(list, bundleID: "com.example.app") == 63513)
        #expect(SimulatorApps.runningPID(list, bundleID: "com.example") == nil)
        #expect(SimulatorApps.runningPID(list, bundleID: "com.example.app.widget") == nil)
    }

    @Test("simctl's replies read as launched, not running, not installed and unclaimed")
    func simulatorReplies() {
        #expect(SimulatorApps.launchedPID("com.example.app: 63513\n", bundleID: "com.example.app") == 63513)
        #expect(SimulatorApps.nothingToTerminate(status: 3, stderr: "Simulator device failed to terminate com.example.app.\nfound nothing to terminate"))
        #expect(SimulatorApps.notInstalled(stderr: "No application record found for that bundle identifier"))
        #expect(SimulatorApps.linkUnclaimed(status: 115, stderr: ""))
        #expect(SimulatorApps.launchArguments(udid: "U", bundleID: "com.example.app", restart: true) == ["simctl", "launch", "--terminate-running-process", "U", "com.example.app"])
    }

    @Test("on a simulator only the Open in prompt that names the app the link went to is answered")
    func promptForNamedAppOnly() {
        let tree = FakeUI.tree([
            FakeUI.node(.other, label: "Open in “Maps”?", frame: FakeUI.frame(41, 388, 320, 126)),
            FakeUI.node(.button, label: "Open", frame: FakeUI.frame(205, 450, 140, 48)),
        ])
        #expect(ExpoDevLauncher.openLinkPrompt(in: tree, appName: "OffsiderPlaygroundRN") == nil)
        #expect(ExpoDevLauncher.openLinkPrompt(in: tree, appName: "Maps")?.label == "Open")
    }

    // MARK: Which app, and the allowance

    @MainActor
    static func route(_ device: DeviceID, allowance: DeviceAllowance?) -> DeviceRouter.Route {
        DeviceRouter.Route(backend: FakeDeviceBackend(platform: device.platform, trees: []), device: device, allowance: allowance)
    }

    static func gate(_ allowance: DeviceAllowance) -> DevicePolicyGate {
        .fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [allowance])), now: PolicyFixtures.now)
    }

    static func option(_ app: String?) -> AppTargetOption {
        var option = AppTargetOption()
        option.bundleID = app
        return option
    }

    @Test("the app is --app, else offsider.login.json's for the platform, else a phone's only pinned app")
    @MainActor
    func targetFallbacks() throws {
        let pinned = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: ["com.example.pinned"])
        let profile = LoginProfile(bundleID: "com.example.ios", package: "com.example.android")
        let phone = Self.route(Self.phone, allowance: pinned)
        #expect(try AppTarget.resolve(Self.option(nil), route: phone, command: "info", gate: Self.gate(pinned), profile: { nil }) == "com.example.pinned")
        #expect(try AppTarget.resolve(Self.option(nil), route: Self.route(Self.simulator, allowance: nil), command: "info", profile: { profile }) == "com.example.ios")
        #expect(try AppTarget.resolve(Self.option("com.example.named"), route: Self.route(Self.simulator, allowance: nil), command: "info", profile: { profile }) == "com.example.named")
    }

    @Test("with no app to act on, the command exits 64 naming --app")
    @MainActor
    func targetRequired() {
        let error = #expect(throws: CLIError.self) {
            try AppTarget.resolve(Self.option(nil), route: Self.route(Self.simulator, allowance: nil), command: "launch", profile: { nil })
        }
        #expect(error?.reason == .usage)
        #expect(error?.userFacingDescription.contains("--app") == true)
    }

    @Test("on a phone pinned to one app, another app is app_not_allowed and names devices add")
    @MainActor
    func pinnedPhoneRefusesOtherApp() {
        let pinned = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: ["com.example.pinned"])
        let error = #expect(throws: CLIError.self) {
            try AppTarget.resolve(Self.option("com.example.other"), route: Self.route(Self.phone, allowance: pinned), command: "stop", gate: Self.gate(pinned), profile: { nil })
        }
        #expect(error?.reason == .appNotAllowed)
        #expect(error?.hint == "offsider devices add")
    }

    @Test("a phone allowed for any app still refuses browsers, home screens and system apps", arguments: ["com.android.chrome", "com.android.settings", "com.google.android.apps.nexuslauncher"])
    @MainActor
    func anyAppPhoneRefusesDenyList(_ app: String) {
        let any = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: [])
        let error = #expect(throws: CLIError.self) {
            try AppTarget.resolve(Self.option(app), route: Self.route(Self.phone, allowance: any), command: "launch", gate: Self.gate(any), profile: { nil })
        }
        #expect(error?.reason == .appNotAllowed)
    }

    @Test("a phone allowed for any app drives the app a command names")
    @MainActor
    func anyAppPhoneAllowsNamedApp() throws {
        let any = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: [])
        #expect(try AppTarget.resolve(Self.option("com.example.app"), route: Self.route(Self.phone, allowance: any), command: "open", gate: Self.gate(any), profile: { nil }) == "com.example.app")
    }

    @Test("a simulator needs no allowance, so a system app is fine there")
    @MainActor
    func simulatorAllowsSystemApp() throws {
        #expect(try AppTarget.resolve(Self.option("com.apple.Preferences"), route: Self.route(Self.simulator, allowance: nil), command: "launch", profile: { nil }) == "com.apple.Preferences")
    }
}
