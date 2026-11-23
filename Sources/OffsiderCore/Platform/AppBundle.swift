import Darwin
import Foundation

/// A built iOS `.app` folder, as its `Info.plist` describes it. Read on the Mac before anything reaches a device.
public struct AppBundle: Equatable, Sendable {
    /// What the bundle was built to run on.
    public enum Destination: String, Equatable, Sendable {
        case device
        case simulator

        var buildFix: String {
            switch self {
            case .device: return "Build it for a device (xcodebuild -destination 'generic/platform=iOS')"
            case .simulator: return "Build it for the simulator (xcodebuild -destination 'generic/platform=iOS Simulator')"
            }
        }

        var taker: String {
            switch self {
            case .device: return "an iPhone or iPad"
            case .simulator: return "a simulator"
            }
        }
    }

    /// The folder itself, with any symlink on the way resolved.
    public var path: String
    public var bundleID: String
    public var destination: Destination

    public init(path: String, bundleID: String, destination: Destination) {
        self.path = path
        self.bundleID = bundleID
        self.destination = destination
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The bundle at `path`, which must be a `.app` folder built for `destination`; every refusal is `bundle_unreadable` and sends nothing.
    public static func read(_ path: String, for destination: Destination) throws(AppLifecycleError) -> AppBundle {
        let shown = TerminalText.field(path)
        switch (path as NSString).pathExtension.lowercased() {
        case "ipa":
            throw AppLifecycleError(.bundleUnreadable, "\(shown) is an .ipa archive, and Offsider installs a built .app folder. Nothing was sent. Unzip it and pass the Payload/<name>.app inside.")
        case "apk", "aab":
            throw AppLifecycleError(.bundleUnreadable, "\(shown) is an Android file, and \(destination.taker) takes a built .app folder. Nothing was sent.")
        default:
            break
        }
        guard let resolved = unsafe realpath(path, nil) else {
            throw AppLifecycleError(.bundleUnreadable, "No app at \(shown). Nothing was sent.")
        }
        defer { unsafe free(resolved) }
        let folder = unsafe String(cString: resolved)
        var info = stat()
        guard unsafe lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, (folder as NSString).pathExtension.lowercased() == "app" else {
            throw AppLifecycleError(.bundleUnreadable, "\(shown) is not a built .app folder, so nothing was sent. Pass the folder Xcode builds, such as Build/Products/Debug-iphoneos/<name>.app.")
        }
        let plist = try propertyList(inBundle: folder, shown: shown)
        let id = try identifier(in: plist, shown: shown)
        let built = try platform(in: plist, shown: shown)
        guard built == destination else {
            throw AppLifecycleError(.bundleUnreadable, "\(shown) is a \(built.rawValue) build, and \(destination.taker) takes a \(destination.rawValue) build. Nothing was sent. \(destination.buildFix).")
        }
        return AppBundle(path: folder, bundleID: id, destination: destination)
    }

    /// `CFBundleIdentifier` of the bundle at `folder`, never read through a symlink.
    static func identifier(inBundle folder: String, shown: String) throws(AppLifecycleError) -> String {
        try identifier(in: try propertyList(inBundle: folder, shown: shown), shown: shown)
    }

    private static func propertyList(inBundle folder: String, shown: String) throws(AppLifecycleError) -> [String: Any] {
        guard let plist = UntrustedRead.propertyList(atPath: (folder as NSString).appendingPathComponent("Info.plist")) else {
            throw AppLifecycleError(.bundleUnreadable, "\(shown) has no Info.plist Offsider could read, so nothing was sent. Build the app again.")
        }
        return plist
    }

    private static func identifier(in plist: [String: Any], shown: String) throws(AppLifecycleError) -> String {
        guard let id = plist["CFBundleIdentifier"] as? String, (try? ExpoDevClient.validate(appID: id)) != nil else {
            throw AppLifecycleError(.bundleUnreadable, "\(shown) names no usable bundle id in its Info.plist, so nothing was sent. Build the app again.")
        }
        return id
    }

    private static func platform(in plist: [String: Any], shown: String) throws(AppLifecycleError) -> Destination {
        let names = (plist["CFBundleSupportedPlatforms"] as? [String]) ?? (plist["DTPlatformName"] as? String).map { [$0] } ?? []
        let lowered = names.map { $0.lowercased() }
        if lowered.contains("iphoneos") { return .device }
        if lowered.contains("iphonesimulator") { return .simulator }
        let built = names.first.map { "is built for \(TerminalText.field($0))" } ?? "does not say what it was built for"
        throw AppLifecycleError(.bundleUnreadable, "\(shown) \(built), so nothing was sent. Offsider installs an iOS or iPadOS app built by Xcode.")
    }
}

/// A private copy of a bundle, checked after it was made: what is checked is what is sent.
public struct AppBundleClone: Equatable, Sendable {
    /// The cloned `.app`, inside a 0700 folder of its own.
    public let path: String
    public let bytes: Int

    /// Deletes the clone and its folder.
    public func remove() {
        AppBundleStaging.remove((path as NSString).deletingLastPathComponent)
    }
}

public enum AppBundleStaging {
    public static let directoryName = "installs"
    /// Longer than any install runs, so only a clone a killed command left behind is swept.
    static let staleAfter: TimeInterval = 60 * 60

    /// Clones `bundle` into `<root>/installs/<uuid>/` and checks the clone: its id is `app`, and every app or extension inside carries an id under `app`.
    public static func clone(_ bundle: AppBundle, as app: String, root: String = OffsiderPrivateDirectory.root, now: Date = Date()) throws -> AppBundleClone {
        let installs = try OffsiderPrivateDirectory.ensureSubdirectory(directoryName, root: root)
        sweep(installs, now: now)
        let folder = (installs as NSString).appendingPathComponent(UUID().uuidString)
        try OffsiderPrivateDirectory.ensurePrivateDirectory(folder, uid: getuid())
        let path = (folder as NSString).appendingPathComponent(bundle.name)
        do {
            // One call clones the whole folder on APFS, about 15 times faster than a file at a time; another volume or file system falls back to a copy.
            guard unsafe (clonefile(bundle.path, path, UInt32(CLONE_NOFOLLOW)) == 0
                || copyfile(bundle.path, path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)) == 0) else {
                let reason = unsafe String(cString: strerror(errno))
                throw AppLifecycleError(.bundleUnreadable, "Offsider could not copy \(TerminalText.field(bundle.path)) to check it (\(reason)), so nothing was sent.")
            }
            let shown = TerminalText.field(bundle.path)
            let cloned = try AppBundle.identifier(inBundle: path, shown: shown)
            guard cloned == app else {
                throw AppLifecycleError(.packageMismatch, "\(shown) changed while Offsider read it and is now \(cloned), not \(app). Nothing was sent.")
            }
            return AppBundleClone(path: path, bytes: try contents(of: path, app: app, shown: shown))
        } catch {
            remove(folder)
            throw error
        }
    }

    /// The clone's size, after every nested `.app` and `.appex` proved to belong to `app`. A link may only point inside the clone, so nothing checked here can change afterwards.
    private static func contents(of path: String, app: String, shown: String) throws(AppLifecycleError) -> Int {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let root = resolved(path), let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: keys) else {
            throw AppLifecycleError(.bundleUnreadable, "Offsider could not list its copy of \(shown), so nothing was sent.")
        }
        var bytes = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let inner = TerminalText.field(String(item.path.dropFirst(path.count + 1)))
            if values?.isSymbolicLink == true {
                guard let target = resolved(item.path), target.hasPrefix(root + "/") else {
                    throw AppLifecycleError(.bundleUnreadable, "\(inner) in \(shown) is a link that leaves the app or points nowhere, so nothing was sent. Build the app again without it.")
                }
            } else if values?.isRegularFile == true {
                bytes += values?.fileSize ?? 0
                continue
            } else if values?.isDirectory != true {
                continue
            }
            guard ["app", "appex"].contains(item.pathExtension.lowercased()) else { continue }
            let id = try AppBundle.identifier(inBundle: item.path, shown: "\(inner) in \(shown)")
            guard id.hasPrefix(app + ".") else {
                throw AppLifecycleError(.packageMismatch, "\(inner) in \(shown) is \(id), which is not part of \(app). Nothing was sent. Build \(app) with its own extensions only.")
            }
        }
        return bytes
    }

    private static func resolved(_ path: String) -> String? {
        guard let pointer = unsafe realpath(path, nil) else { return nil }
        defer { unsafe free(pointer) }
        return unsafe String(cString: pointer)
    }

    private static func sweep(_ installs: String, now: Date) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: installs)) ?? [] {
            let folder = (installs as NSString).appendingPathComponent(name)
            guard let made = (try? FileManager.default.attributesOfItem(atPath: folder))?[.modificationDate] as? Date,
                  now.timeIntervalSince(made) > staleAfter else { continue }
            remove(folder)
        }
    }

    /// A bundle can hold read-only folders, which only delete once they are writable again.
    static func remove(_ folder: String) {
        if (try? FileManager.default.removeItem(atPath: folder)) != nil { return }
        let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: [.isDirectoryKey])
        for case let item as URL in walker ?? FileManager.DirectoryEnumerator() where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            _ = unsafe chmod(item.path, S_IRWXU)
        }
        try? FileManager.default.removeItem(atPath: folder)
    }
}

/// The copy of an app a device already holds, read before an install or a removal.
public struct InstalledAppCopy: Equatable, Sendable {
    public var app: String
    /// False for a copy from the App Store or TestFlight, which holds a person's own data and saved logins.
    public var builtByDeveloper: Bool

    public init(app: String, builtByDeveloper: Bool) {
        self.app = app
        self.builtByDeveloper = builtByDeveloper
    }
}

/// Optional capability: installing a built `.app` and removing an app, on an iPhone, iPad or simulator.
@MainActor
public protocol AppBundleManaging: DeviceBackend {
    /// Clones and checks the bundle, hands a copy already on the device to `replacing` (which throws to stop), then installs the clone and deletes it.
    func installBundle(_ bundle: AppBundle, as app: String, on id: DeviceID, replacing: (InstalledAppCopy) async throws -> Void) async throws -> AppInstall
    /// Hands the installed copy to `removing` (which throws to stop), then removes the app and its data. An app that is not installed is no error.
    func removeBundle(_ app: String, on id: DeviceID, removing: (InstalledAppCopy) async throws -> Void) async throws -> AppUninstall
}
