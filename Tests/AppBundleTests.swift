import Foundation
import OffsiderCore
import Testing

/// Made-up `.app` folders in a temp directory: an `Info.plist`, nested bundles and an optional profile.
struct AppBundleFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The resolved path of a new bundle; `platform` nil leaves the plist without one.
    @discardableResult
    func app(_ name: String = "Example.app", id: String? = "com.example.app", platform: String? = "iPhoneOS", nested: [String: String] = [:], profile: Data? = nil) throws -> String {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try Self.write(id: id, platform: platform, to: folder)
        try Data(repeating: 7, count: 2048).write(to: folder.appendingPathComponent("Example"))
        for (path, nestedID) in nested {
            try Self.write(id: nestedID, platform: platform, to: folder.appendingPathComponent(path, isDirectory: true))
        }
        if let profile { try profile.write(to: folder.appendingPathComponent("embedded.mobileprovision")) }
        return try #require(realpath(folder.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) })
    }

    static func write(id: String?, platform: String?, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": "Example"]
        if let id { plist["CFBundleIdentifier"] = id }
        if let platform { plist["CFBundleSupportedPlatforms"] = [platform] }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
    }

    var privateRoot: String { root.appendingPathComponent("private", isDirectory: true).path }

    /// What is left under `installs/` in the private root: nothing, once every clone is deleted.
    var clones: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: privateRoot + "/installs")) ?? []
    }
}

@Suite("iOS app bundles read on the Mac")
struct AppBundleTests {
    static let app = "com.example.app"

    @Test("a device build and a simulator build each read with their id, and each is refused for the other")
    func readsIDAndPlatform() throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let device = try fixture.app("Device.app", platform: "iPhoneOS")
        let simulator = try fixture.app("Simulator.app", platform: "iPhoneSimulator")

        #expect(try AppBundle.read(device, for: .device) == AppBundle(path: device, bundleID: Self.app, destination: .device))
        #expect(try AppBundle.read(simulator, for: .simulator).destination == .simulator)

        let onPhone = #expect(throws: AppLifecycleError.self) { try AppBundle.read(simulator, for: .device) }
        #expect(onPhone?.kind == .bundleUnreadable)
        #expect(onPhone?.message.contains("is a simulator build") == true && onPhone?.message.contains("generic/platform=iOS'") == true)
        let onSimulator = #expect(throws: AppLifecycleError.self) { try AppBundle.read(device, for: .simulator) }
        #expect(onSimulator?.kind == .bundleUnreadable)
        #expect(onSimulator?.message.contains("is a device build") == true)
    }

    @Test("what is not a built iOS app is refused with its fix, and nothing is sent", arguments: [
        ("Example.ipa", "Payload/<name>.app"),
        ("app-debug.apk", "Android file"),
        ("Missing.app", "No app at"),
        ("Plain.txt", "not a built .app folder"),
        ("Folder", "not a built .app folder"),
    ])
    func refusals(name: String, says: String) throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        try Data("x".utf8).write(to: fixture.root.appendingPathComponent("Example.ipa"))
        try Data("x".utf8).write(to: fixture.root.appendingPathComponent("app-debug.apk"))
        try Data("x".utf8).write(to: fixture.root.appendingPathComponent("Plain.txt"))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Folder"), withIntermediateDirectories: true)

        let error = #expect(throws: AppLifecycleError.self) { try AppBundle.read(fixture.root.appendingPathComponent(name).path, for: .device) }
        #expect(error?.kind == .bundleUnreadable)
        #expect(error?.message.contains(says) == true, "\(error?.message ?? "")")
        #expect(error?.message.contains("othing was sent") == true)
    }

    @Test("a bundle with no id, an id that is not one, a Mac build or no platform is refused")
    func unusablePlists() throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let cases: [(String, String?, String?, String)] = [
            ("NoID.app", nil, "iPhoneOS", "names no usable bundle id"),
            ("BadID.app", "not an id; rm -rf", "iPhoneOS", "names no usable bundle id"),
            ("Mac.app", Self.app, "MacOSX", "is built for"),
            ("NoPlatform.app", Self.app, nil, "does not say what it was built for"),
        ]
        for (name, id, platform, says) in cases {
            let path = try fixture.app(name, id: id, platform: platform)
            let error = #expect(throws: AppLifecycleError.self) { try AppBundle.read(path, for: .device) }
            #expect(error?.kind == .bundleUnreadable && error?.message.contains(says) == true, "\(name): \(error?.message ?? "")")
        }
    }

    @Test("an Info.plist that is a symlink is not followed")
    func symlinkedPlist() throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let real = try fixture.app("Real.app")
        let fake = fixture.root.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fake.appendingPathComponent("Info.plist").path, withDestinationPath: real + "/Info.plist")

        let error = #expect(throws: AppLifecycleError.self) { try AppBundle.read(fake.path, for: .device) }
        #expect(error?.kind == .bundleUnreadable && error?.message.contains("no Info.plist Offsider could read") == true)
    }

    @Test("a symlink to the bundle resolves to the folder itself, which is what gets cloned")
    func symlinkedBundle() throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let real = try fixture.app("Real.app")
        let link = fixture.root.appendingPathComponent("Latest.app").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(try AppBundle.read(link, for: .device).path == real)
    }

    @Test("the clone is private, holds the bundle whole and is gone after remove")
    func clonePrivateAndRemoved() throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let path = try fixture.app(nested: ["PlugIns/Widget.appex": "com.example.app.widget", "Watch/Watch.app": "com.example.app.watchkitapp"])
        let clone = try AppBundleStaging.clone(try AppBundle.read(path, for: .device), as: Self.app, root: fixture.privateRoot)

        #expect(clone.path.hasPrefix(fixture.privateRoot + "/installs/") && clone.path.hasSuffix("/Example.app"))
        #expect(clone.path != path)
        let folder = (clone.path as NSString).deletingLastPathComponent
        #expect((try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(FileManager.default.fileExists(atPath: clone.path + "/PlugIns/Widget.appex/Info.plist"))
        #expect(clone.bytes > 2048)

        clone.remove()
        #expect(fixture.clones.isEmpty)
    }

    @Test("a nested app or extension with another app's id is refused, and its clone is deleted", arguments: [
        ("PlugIns/Share.appex", "com.example.other.share"),
        ("Watch/Watch.app", "com.example.application"),
        ("AppClips/Clip.app", "com.example.app"),
        ("Frameworks/Kit.framework/PlugIns/Deep.appex", "org.example.elsewhere"),
    ])
    func foreignNestedBundle(nestedPath: String, id: String) throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let path = try fixture.app(nested: [nestedPath: id])
        let bundle = try AppBundle.read(path, for: .device)

        let error = #expect(throws: AppLifecycleError.self) { _ = try AppBundleStaging.clone(bundle, as: Self.app, root: fixture.privateRoot) }
        #expect(error?.kind == .packageMismatch)
        #expect(error?.message.contains(id) == true && error?.message.contains("Nothing was sent") == true)
        #expect(error?.message.contains("\"\(nestedPath)\" in ") == true, "\(error?.message ?? "")")
        #expect(fixture.clones.isEmpty)
    }

    @Test("a nested extension whose Info.plist cannot be read is refused rather than skipped")
    func unreadableNestedBundle() throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let path = try fixture.app()
        try FileManager.default.createDirectory(atPath: path + "/PlugIns/Empty.appex", withIntermediateDirectories: true)
        let bundle = try AppBundle.read(path, for: .device)

        let error = #expect(throws: AppLifecycleError.self) { _ = try AppBundleStaging.clone(bundle, as: Self.app, root: fixture.privateRoot) }
        #expect(error?.kind == .bundleUnreadable)
        #expect(fixture.clones.isEmpty)
    }

    @Test("a link that leaves the app, or points nowhere, is refused; one that stays inside is kept and its target still checked", arguments: [
        ("PlugIns/Escape.appex", "/usr/share", AppLifecycleError.Kind.bundleUnreadable),
        ("Notes.txt", "/etc/hosts", AppLifecycleError.Kind.bundleUnreadable),
        ("Dangling", "nowhere", AppLifecycleError.Kind.bundleUnreadable),
        ("PlugIns/Alias.appex", "../Hidden", AppLifecycleError.Kind.packageMismatch),
    ])
    func links(name: String, target: String, kind: AppLifecycleError.Kind) throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let path = try fixture.app()
        try AppBundleFixture.write(id: "com.example.other.share", platform: "iPhoneOS", to: URL(fileURLWithPath: path + "/Hidden"))
        try FileManager.default.createDirectory(atPath: path + "/PlugIns", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path + "/" + name, withDestinationPath: target)
        let bundle = try AppBundle.read(path, for: .device)

        let error = #expect(throws: AppLifecycleError.self) { _ = try AppBundleStaging.clone(bundle, as: Self.app, root: fixture.privateRoot) }
        #expect(error?.kind == kind, "\(error?.message ?? "")")
        #expect(fixture.clones.isEmpty)

        try FileManager.default.removeItem(atPath: path + "/" + name)
        try FileManager.default.createSymbolicLink(atPath: path + "/Inside", withDestinationPath: "Example")
        let clone = try AppBundleStaging.clone(bundle, as: Self.app, root: fixture.privateRoot)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: clone.path + "/Inside")) == "Example")
        clone.remove()
    }

    @Test("a bundle swapped after it was read is caught on the clone, so what was checked is what is sent")
    func swappedAfterRead() throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let path = try fixture.app()
        let bundle = try AppBundle.read(path, for: .device)
        try AppBundleFixture.write(id: "com.example.swapped", platform: "iPhoneOS", to: URL(fileURLWithPath: path))

        let error = #expect(throws: AppLifecycleError.self) { _ = try AppBundleStaging.clone(bundle, as: Self.app, root: fixture.privateRoot) }
        #expect(error?.kind == .packageMismatch && error?.message.contains("com.example.swapped") == true)
        #expect(fixture.clones.isEmpty)
    }

    @Test("a clone a killed command left behind is swept by the next install, and a fresh one is kept")
    func staleClonesSwept() throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let bundle = try AppBundle.read(try fixture.app(), for: .device)
        let old = try AppBundleStaging.clone(bundle, as: Self.app, root: fixture.privateRoot)
        let fresh = try AppBundleStaging.clone(bundle, as: Self.app, root: fixture.privateRoot, now: Date().addingTimeInterval(60))
        #expect(fixture.clones.count == 2)

        let later = try AppBundleStaging.clone(bundle, as: Self.app, root: fixture.privateRoot, now: Date().addingTimeInterval(2 * 60 * 60))
        #expect(!FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: fresh.path))
        #expect(fixture.clones.count == 1)
        later.remove()
    }

    @Test("install JSON names the path on every platform, and keeps apk on Android")
    func installJSON() {
        let install = AppInstall(app: Self.app, replaced: true, bytes: 88_211_456, milliseconds: 9412)
        let ios = AppManagementReport.install(install, path: "build/Example.app", on: DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios))
        #expect(ios == #"{"version":1,"action":"install","device":"00000000-0000-0000-0000-000000000001","platform":"ios","app":"com.example.app","path":"build/Example.app","replaced":true,"bytes":88211456,"milliseconds":9412}"#)
        let android = AppManagementReport.install(install, path: "build/app.apk", on: DeviceID(rawValue: "emulator-5554", platform: .android))
        #expect(android.contains(#""path":"build/app.apk","apk":"build/app.apk","replaced":true"#))
    }
}
