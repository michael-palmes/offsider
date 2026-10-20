import OffsiderCore
import Testing

@Suite("System app deny-list")
struct SystemAppDenyListTests {
    @Test("browsers, system UI and the apps that hold personal data are refused on iOS", arguments: [
        ("com.apple.mobilesafari", SystemAppDenyList.Category.browser),
        ("com.apple.SafariViewService", .browser),
        ("com.google.chrome.ios", .browser),
        ("com.apple.springboard", .systemUI),
        ("com.apple.mobilemail", .mail),
        ("com.apple.MobileSMS", .messages),
        ("com.apple.Passwords", .passwords),
        ("com.apple.Preferences", .settings),
        ("com.apple.Passbook", .wallet),
        ("com.apple.Health", .health),
        ("com.apple.AppStore", .store),
    ])
    func ios(app: String, category: SystemAppDenyList.Category) {
        #expect(SystemAppDenyList.category(of: app, platform: .ios) == category)
        #expect(SystemAppDenyList.isDenied(app, platform: .ios))
        #expect(SystemAppDenyList.refusal(app, platform: .ios)?.hasPrefix("\(app) is ") == true)
    }

    @Test("browsers, system UI and the apps that hold personal data are refused on Android", arguments: [
        ("com.android.chrome", SystemAppDenyList.Category.browser),
        ("com.sec.android.app.sbrowser", .browser),
        ("com.android.systemui", .systemUI),
        ("com.android.settings", .settings),
        ("com.google.android.gm", .mail),
        ("com.google.android.apps.messaging", .messages),
        ("com.android.vending", .store),
        ("com.google.android.gms", .systemUI),
        ("com.google.android.packageinstaller", .systemUI),
        ("com.google.android.apps.authenticator2", .passwords),
    ])
    func android(app: String, category: SystemAppDenyList.Category) {
        #expect(SystemAppDenyList.category(of: app, platform: .android) == category)
    }

    @Test("an app under test is allowed, and a list is per platform")
    func allowed() {
        #expect(!SystemAppDenyList.isDenied("com.mpalmes.offsider.playground", platform: .ios))
        #expect(!SystemAppDenyList.isDenied("com.example.app", platform: .android))
        #expect(SystemAppDenyList.refusal("com.example.app", platform: .ios) == nil)
        #expect(!SystemAppDenyList.isDenied("com.android.chrome", platform: .ios))
    }

    @Test("browser channels, Samsung's apps, mail, password and authenticator apps are denied by id or prefix", arguments: [
        ("com.chrome.beta", DevicePlatform.android), ("com.chrome.dev", .android), ("com.chrome.canary", .android),
        ("org.mozilla.fenix", .android), ("org.mozilla.focus", .android), ("org.mozilla.klar", .android),
        ("com.samsung.android.messaging", .android), ("com.sec.android.app.sbrowser.beta", .android),
        ("com.microsoft.office.outlook", .android), ("com.onepassword.android", .android), ("com.1password.1password", .android),
        ("com.x8bit.bitwarden", .android), ("com.authy.authy", .android), ("com.azure.authenticator", .android),
        ("org.mozilla.ios.Focus", .ios), ("org.mozilla.ios.Klar", .ios), ("com.google.Gmail", .ios), ("com.microsoft.Office.Outlook", .ios),
        ("com.agilebits.onepassword-ios", .ios), ("com.1password.1password", .ios), ("com.8bit.bitwarden", .ios), ("com.authy", .ios),
        ("com.microsoft.azureauthenticator", .ios), ("com.google.Authenticator", .ios), ("com.apple.findmy", .ios), ("com.apple.Passwords", .ios),
    ])
    func additions(app: String, platform: DevicePlatform) {
        #expect(SystemAppDenyList.isDenied(app, platform: platform))
        #expect(SystemAppDenyList.refusal(app, platform: platform)?.hasPrefix("\(app) is ") == true)
    }

    @Test("a prefix rule never catches an app that only shares a word with it", arguments: [
        ("com.chromecast.example", DevicePlatform.android), ("org.mozillafan.app", .android), ("com.example.app", .android),
        ("com.samsung.android.example", .android), ("com.example.chrome", .ios),
    ])
    func prefixesStayNarrow(app: String, platform: DevicePlatform) {
        #expect(!SystemAppDenyList.isDenied(app, platform: platform))
    }

    @Test("the managed deniedBundleIDs list adds exact ids and prefixes, and iOS ids compare without case")
    func managedList() {
        SystemAppDenyList.$managedOverride.withValue(["com.example.bank", "com.example.vault."]) {
            #expect(SystemAppDenyList.category(of: "com.example.bank", platform: .android) == .managed)
            #expect(SystemAppDenyList.category(of: "com.example.vault.beta", platform: .android) == .managed)
            #expect(SystemAppDenyList.category(of: "COM.EXAMPLE.BANK", platform: .ios) == .managed)
            #expect(!SystemAppDenyList.isDenied("com.example.bankapp", platform: .android))
            #expect(!SystemAppDenyList.isDenied("com.example.app", platform: .android))
            #expect(SystemAppDenyList.refusal("com.example.bank", platform: .android) == "com.example.bank is on your organisation's denied list, which Offsider never signs in to or drives")
        }
        #expect(!SystemAppDenyList.isDenied("com.example.bank", platform: .android))
    }

    @Test("deniedBundleIDs is read only when forced, and a value of the wrong type refuses every physical device")
    func managedKey() {
        let listed = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: [ManagedDevicePolicy.deniedBundleIDsKey: .strings(["com.example.bank"])]))
        #expect(listed.deniedBundleIDs == ["com.example.bank"])
        #expect(listed.present && !listed.unreadable)
        #expect(ManagedDevicePolicy.read(from: FakeManagedPreferences()).deniedBundleIDs == nil)

        let wrong = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: [ManagedDevicePolicy.deniedBundleIDsKey: .bool(true)]))
        #expect(wrong.unreadable)
        let decision = PhysicalDevicePolicy(managed: wrong, list: PhysicalDevicePolicyTests.allowed).decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now)
        #expect(decision == .refused(.managedUnreadable))
    }
}
