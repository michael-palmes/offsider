import Foundation

/// Apps Offsider never signs in to, links a login to, or drives on a physical phone: browsers and the system apps
/// that hold mail, messages, passwords, payments, photos, health data and settings.
public enum SystemAppDenyList {
    public enum Category: String, Sendable {
        case browser, systemUI, mail, messages, passwords, settings, wallet, photos, health, store, contacts, phone, files, findMy
        /// Named by the managed `deniedBundleIDs` key.
        case managed
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
        "com.apple.DocumentsApp": .files,
        "com.apple.findmy": .findMy,
        "com.microsoft.Office.Outlook": .mail,
        "com.google.Gmail": .mail,
        "com.agilebits.onepassword-ios": .passwords,
        "com.1password.1password": .passwords,
        "com.8bit.bitwarden": .passwords,
        "com.authy": .passwords,
        "com.microsoft.azureauthenticator": .passwords,
        "com.google.Authenticator": .passwords
    ]

    /// Every id that starts with one of these is denied too: browser channels (Beta, Dev, Canary, Nightly, Focus, Klar).
    static let iosPrefixes: [(String, Category)] = [
        ("org.mozilla.ios.", .browser),
        ("com.google.chrome.ios", .browser),
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
        "com.google.android.apps.authenticator2": .passwords,
        "com.microsoft.office.outlook": .mail,
        "com.onepassword.android": .passwords,
        "com.1password.1password": .passwords,
        "com.agilebits.onepassword": .passwords,
        "com.x8bit.bitwarden": .passwords,
        "com.authy.authy": .passwords,
        "com.azure.authenticator": .passwords,
        "com.google.android.apps.adm": .findMy
    ]

    /// Chrome's Beta, Dev and Canary (`com.chrome.`), every Firefox channel including Nightly, Focus and Klar (`org.mozilla.`),
    /// Samsung Internet and Samsung's system apps (`com.sec.android.app.`) and Samsung Messages.
    static let androidPrefixes: [(String, Category)] = [
        ("com.android.chrome", .browser),
        ("com.chrome.", .browser),
        ("org.mozilla.", .browser),
        ("com.sec.android.app.", .systemUI),
        ("com.samsung.android.messaging", .messages),
    ]

    /// The managed `deniedBundleIDs` list, read once per process; tests inject one. An entry ending in `.` is a prefix.
    @TaskLocal public static var managedOverride: [String]?
    static let managedLive: [String] = ManagedDevicePolicy.read(from: LiveManagedPreferences()).deniedBundleIDs ?? []
    static var managed: [String] { managedOverride ?? managedLive }

    /// The category that keeps `appID` off limits on `platform`, or nil when the app may be driven.
    public static func category(of appID: String, platform: DevicePlatform) -> Category? {
        let exact = platform == .ios ? ios : android
        if let category = exact[appID] { return category }
        let prefixes = platform == .ios ? iosPrefixes : androidPrefixes
        if let match = prefixes.first(where: { appID.hasPrefix($0.0) }) { return match.1 }
        if managed.contains(where: { matches(appID, entry: $0, platform: platform) }) { return .managed }
        return nil
    }

    /// A managed entry ending in `.` is a prefix; iOS ids compare without case.
    static func matches(_ appID: String, entry: String, platform: DevicePlatform) -> Bool {
        let entry = entry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return false }
        let id = platform == .ios ? appID.lowercased() : appID
        let listed = platform == .ios ? entry.lowercased() : entry
        return listed.hasSuffix(".") ? id.hasPrefix(listed) : id == listed
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
        case .findMy: what = "the Find My app"
        case .managed: what = "on your organisation's denied list"
        }
        return "\(appID) is \(what), which Offsider never signs in to or drives"
    }
}
