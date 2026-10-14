import Foundation

/// Apps Offsider never signs in to, links a login to, or drives on a physical phone: browsers and the system apps
/// that hold mail, messages, passwords, payments, photos, health data and settings.
public enum SystemAppDenyList {
    public enum Category: String, Sendable {
        case browser, systemUI, mail, messages, passwords, settings, wallet, photos, health, store, contacts, phone, files
    }

    static let ios: [String: Category] = [
        "com.apple.mobilesafari": .browser,
        "com.apple.SafariViewService": .browser,
        "com.google.chrome.ios": .browser,
        "org.mozilla.ios.Firefox": .browser,
        "com.microsoft.msedge": .browser,
        "com.brave.ios.browser": .browser,
        "com.duckduckgo.mobile.ios": .browser,
        "com.apple.springboard": .systemUI,
        "com.apple.mobilemail": .mail,
        "com.apple.MobileSMS": .messages,
        "com.apple.Passwords": .passwords,
        "com.apple.Preferences": .settings,
        "com.apple.mobileslideshow": .photos,
        "com.apple.Health": .health,
        "com.apple.Passbook": .wallet,
        "com.apple.AppStore": .store,
        "com.apple.MobileAddressBook": .contacts,
        "com.apple.mobilephone": .phone,
        "com.apple.facetime": .phone,
        "com.apple.DocumentsApp": .files
    ]

    static let android: [String: Category] = [
        "com.android.chrome": .browser,
        "com.sec.android.app.sbrowser": .browser,
        "org.mozilla.firefox": .browser,
        "com.brave.browser": .browser,
        "com.microsoft.emmx": .browser,
        "com.opera.browser": .browser,
        "com.duckduckgo.mobile.android": .browser,
        "com.android.systemui": .systemUI,
        "com.android.settings": .settings,
        "com.google.android.gm": .mail,
        "com.google.android.apps.messaging": .messages,
        "com.android.vending": .store,
        "com.google.android.gms": .systemUI,
        "com.google.android.apps.photos": .photos,
        "com.google.android.contacts": .contacts,
        "com.google.android.dialer": .phone,
        "com.android.permissioncontroller": .systemUI,
        "com.google.android.permissioncontroller": .systemUI,
        "com.google.android.packageinstaller": .systemUI,
        "com.google.android.apps.walletnfcrel": .wallet,
        "com.google.android.apps.authenticator2": .passwords
    ]

    /// The category that keeps `appID` off limits on `platform`, or nil when the app may be driven.
    public static func category(of appID: String, platform: DevicePlatform) -> Category? {
        switch platform {
        case .ios: return ios[appID]
        case .android: return android[appID]
        }
    }

    public static func isDenied(_ appID: String, platform: DevicePlatform) -> Bool {
        category(of: appID, platform: platform) != nil
    }

    /// One line for an error message: why Offsider will not act on `appID`.
    public static func refusal(_ appID: String, platform: DevicePlatform) -> String? {
        guard let category = category(of: appID, platform: platform) else { return nil }
        let what: String
        switch category {
        case .browser: what = "a browser"
        case .systemUI: what = "part of the system UI"
        case .mail: what = "the mail app"
        case .messages: what = "the messages app"
        case .passwords: what = "a password or authenticator app"
        case .settings: what = "the settings app"
        case .wallet: what = "a wallet or payments app"
        case .photos: what = "the photos app"
        case .health: what = "the health app"
        case .store: what = "the app store"
        case .contacts: what = "the contacts app"
        case .phone: what = "the phone app"
        case .files: what = "the files app"
        }
        return "\(appID) is \(what), which Offsider never signs in to or drives"
    }
}
