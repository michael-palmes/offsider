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
}
