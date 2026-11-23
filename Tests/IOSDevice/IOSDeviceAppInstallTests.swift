import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("iPhone and iPad app install and uninstall")
@MainActor
struct IOSDeviceAppInstallTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)
    static let app = "com.example.app"

    struct Stopped: Error {}

    static func reply(_ result: String) -> ProcessCaptureResult {
        ProcessCaptureResult(status: 0, stdout: #"{"info":{"outcome":"success"},"result":\#(result)}"#, stderr: "")
    }

    static func installed(_ ids: String...) -> ProcessCaptureResult {
        reply(#"{"installedApplications":[\#(ids.map { #"{"bundleID":"\#($0)","installationURL":"file:///private/var/containers/Bundle/Application/00000000-0000-4000-8000-000000000001/Example.app/"}"# }.joined(separator: ","))]}"#)
    }

    static let noCopy = reply(#"{"apps":[]}"#)

    static func copy(developer: Bool?) -> ProcessCaptureResult {
        reply(#"{"apps":[{"bundleIdentifier":"\#(app)","name":"Example"\#(developer.map { #","builtByDeveloper":\#($0)"# } ?? "")}]}"#)
    }

    /// devicectl's failure document: what it was trying, over the device's own reason.
    static func refused(_ reason: String, domain: String = "MIInstallerErrorDomain", code: Int = 13) -> ProcessCaptureResult {
        let json = #"{"error":{"domain":"com.apple.dt.CoreDeviceError","code":3002,"userInfo":{"NSLocalizedDescription":{"string":"Failed to install the app on the device."},"NSUnderlyingError":{"error":{"domain":"\#(domain)","code":\#(code),"userInfo":{"NSLocalizedFailureReason":{"string":"\#(reason)"}}}}}}}"#
        return ProcessCaptureResult(status: 1, stdout: json, stderr: "ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002.)\n")
    }

    /// The backend, the fake and the `.app` paths seen by each `device install app` call, with whether the folder existed then.
    final class Setup {
        let fixture: AppBundleFixture
        let devicectl: FakeDevicectl
        let backend: IOSDeviceBackend
        let sent = Sent()

        @MainActor
        init(_ replies: [String: ProcessCaptureResult], queued: [String: [ProcessCaptureResult]] = [:]) throws {
            fixture = try AppBundleFixture()
            let sent = sent
            var all = replies
            all["list"] = ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-list-xcode26.json"), stderr: "")
            devicectl = FakeDevicectl(replies: all, queued: queued) { arguments in
                guard arguments.starts(with: ["device", "install", "app"]) else { return }
                sent.note(arguments[5], existed: FileManager.default.fileExists(atPath: arguments[5] + "/Info.plist"))
            }
            let host = IOSDeviceHost.fake(devicectl, usbmux: FakeUsbmuxListing.onUSB(IOSDeviceFixtures.phone), privateRoot: fixture.privateRoot)
            backend = IOSDeviceBackend(host: host) { _, _ in }
        }

        func bundle(nested: [String: String] = [:], profile: Data? = nil) throws -> AppBundle {
            try AppBundle.read(try fixture.app(nested: nested, profile: profile), for: .device)
        }

        var deviceCalls: [[String]] { devicectl.calls.filter { $0.first == "device" } }
        var installs: [[String]] { devicectl.calls.filter { $0.starts(with: ["device", "install", "app"]) } }
        var uninstalls: [[String]] { devicectl.calls.filter { $0.starts(with: ["device", "uninstall", "app"]) } }
    }

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [(path: String, existed: Bool)] = []

        func note(_ path: String, existed: Bool) { lock.withLock { rows.append((path, existed)) } }
        var all: [(path: String, existed: Bool)] { lock.withLock { rows } }
    }

    @Test("an install sends the private clone with exactly these arguments, reports the app, and deletes the clone")
    func installsTheClone() async throws {
        let setup = try Setup(["apps": Self.noCopy, "install app": Self.installed(Self.app)])
        defer { setup.fixture.remove() }
        let bundle = try setup.bundle(nested: ["PlugIns/Widget.appex": "com.example.app.widget"])

        let install = try await setup.backend.installBundle(bundle, as: Self.app, on: Self.phone) { _ in Issue.record("nothing is installed, so nothing is replaced") }

        let sent = try #require(setup.sent.all.first)
        #expect(setup.installs == [["device", "install", "app", "--device", IOSDeviceFixtures.phone, sent.path, "--json-output", "-", "-q", "--timeout", "300"]])
        #expect(sent.existed && sent.path != bundle.path && sent.path.hasPrefix(setup.fixture.privateRoot + "/installs/"))
        #expect(setup.fixture.clones.isEmpty)
        #expect(install.app == Self.app && !install.replaced && install.bytes > 2048)
        #expect(setup.deviceCalls.first == DevicectlAppProcess.infoArguments(udid: IOSDeviceFixtures.phone, bundleID: Self.app))
    }

    @Test("no argument Offsider sends could build, sign or register a device")
    func noProvisioningFlag() {
        let arguments = DevicectlAppInstall.installArguments(udid: IOSDeviceFixtures.phone, path: "/tmp/Example.app")
        #expect(!arguments.contains { $0.lowercased().contains("provision") || $0.lowercased().contains("register") || $0.lowercased().contains("sign") })
    }

    @Test("a copy already on the device is handed to the caller before anything is sent: developer-built, App Store, or unsaid", arguments: [
        (true as Bool?, true), (false as Bool?, false), (nil as Bool?, false),
    ])
    func handsOverTheInstalledCopy(reported: Bool?, developer: Bool) async throws {
        let setup = try Setup(["apps": Self.copy(developer: reported), "install app": Self.installed(Self.app)])
        defer { setup.fixture.remove() }
        var seen: [InstalledAppCopy] = []

        let install = try await setup.backend.installBundle(try setup.bundle(), as: Self.app, on: Self.phone) { copy in
            #expect(setup.installs.isEmpty)
            seen.append(copy)
        }

        #expect(seen == [InstalledAppCopy(app: Self.app, builtByDeveloper: developer)])
        #expect(install.replaced)
    }

    @Test("when the caller stops at a copy, nothing is sent and the clone is deleted")
    func callerStops() async throws {
        let setup = try Setup(["apps": Self.copy(developer: false), "install app": Self.installed(Self.app)])
        defer { setup.fixture.remove() }

        await #expect(throws: Stopped.self) {
            _ = try await setup.backend.installBundle(try setup.bundle(), as: Self.app, on: Self.phone) { _ in throw Stopped() }
        }

        #expect(setup.installs.isEmpty && setup.uninstalls.isEmpty)
        #expect(setup.fixture.clones.isEmpty)
    }

    @Test("a device that says it installed another app has that app removed at once, and the install fails")
    func wrongInstalledApp() async throws {
        let setup = try Setup(["apps": Self.noCopy, "install app": Self.installed("com.example.intruder"), "uninstall app": Self.reply("{}")])
        defer { setup.fixture.remove() }

        let error = await #expect(throws: AppLifecycleError.self) {
            _ = try await setup.backend.installBundle(try setup.bundle(), as: Self.app, on: Self.phone) { _ in }
        }

        #expect(error?.kind == .installFailed)
        #expect(error?.message.contains("com.example.intruder") == true && error?.message.contains("removed it at once") == true)
        #expect(setup.uninstalls == [DevicectlAppInstall.uninstallArguments(udid: IOSDeviceFixtures.phone, bundleID: "com.example.intruder")])
        #expect(setup.fixture.clones.isEmpty)
    }

    @Test("an install whose reply names no app is settled by reading the app back, which proves nothing when a copy was already there")
    func replyNamesNothing() async throws {
        let listed = try Setup([:], queued: ["apps": [Self.noCopy, Self.copy(developer: true)], "install app": [Self.reply("{}")]])
        defer { listed.fixture.remove() }
        #expect(try await listed.backend.installBundle(try listed.bundle(), as: Self.app, on: Self.phone) { _ in }.app == Self.app)

        let missing = try Setup(["apps": Self.noCopy, "install app": Self.reply("{}")])
        defer { missing.fixture.remove() }
        let error = await #expect(throws: AppLifecycleError.self) {
            _ = try await missing.backend.installBundle(try missing.bundle(), as: Self.app, on: Self.phone) { _ in }
        }
        #expect(error?.kind == .installFailed && error?.message.contains("offsider app info --app \(Self.app)") == true)
        #expect(missing.uninstalls.isEmpty)

        let replaced = try Setup(["apps": Self.copy(developer: true), "install app": Self.reply("{}")])
        defer { replaced.fixture.remove() }
        let unsure = await #expect(throws: AppLifecycleError.self) {
            _ = try await replaced.backend.installBundle(try replaced.bundle(), as: Self.app, on: Self.phone) { _ in }
        }
        #expect(unsure?.kind == .installFailed && unsure?.message.contains("may be the old one") == true)
    }

    @Test("a refusal from the device is install_failed in its own words, with the fix for the reasons Offsider knows", arguments: [
        ("Failed to verify code signature of Example.app : 0xe8008015 (A valid provisioning profile for this executable was not found.)", "No valid provisioning profile covers this device"),
        ("Failed to verify code signature of Example.app : 0xe800801c (No code signature found.)", "code signature was refused"),
        ("There is not enough space on the device to install this app.", "Free some space"),
        ("The app requires a newer version of iOS than this device has.", "older than the build's deployment target"),
        ("The device made up a reason nobody has seen.", "offsider doctor --device"),
        ("Unable to install Cloud Storage Minimum: 0xe800801c (No code signature found.)", "code signature was refused"),
        ("Unable to install Cloud Storage Minimum.", "offsider doctor --device"),
    ])
    func mappedRefusals(reason: String, fix: String) async throws {
        let setup = try Setup(["apps": Self.noCopy, "install app": Self.refused(reason)])
        defer { setup.fixture.remove() }

        let error = await #expect(throws: AppLifecycleError.self) {
            _ = try await setup.backend.installBundle(try setup.bundle(), as: Self.app, on: Self.phone) { _ in }
        }

        #expect(error?.kind == .installFailed)
        #expect(error?.message.contains(reason) == true && error?.message.contains(fix) == true, "\(error?.message ?? "")")
        #expect(setup.fixture.clones.isEmpty)
    }

    @Test("a locked device keeps its own reason, so the person is asked to unlock it")
    func lockedDevice() async throws {
        let setup = try Setup(["apps": Self.noCopy, "install app": Self.refused("The device is passcode protected.", domain: "com.apple.dt.CoreDeviceError", code: 10003)])
        defer { setup.fixture.remove() }

        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await setup.backend.installBundle(try setup.bundle(), as: Self.app, on: Self.phone) { _ in }
        }

        #expect(error?.kind == .locked)
        #expect(setup.fixture.clones.isEmpty)
    }

    @Test("an expired profile, or one that leaves this device out, is refused on the Mac with no call to the device", arguments: [
        ("runner-profile-expired.mobileprovision", "expired on 2026-11-12"),
        ("app-profile-other-device.mobileprovision", "does not list \(IOSDeviceFixtures.phone)"),
    ])
    func profileRefused(fixtureName: String, says: String) async throws {
        let setup = try Setup(["apps": Self.noCopy, "install app": Self.installed(Self.app)])
        defer { setup.fixture.remove() }
        let bundle = try setup.bundle(profile: try IOSDeviceFixtures.data(fixtureName))

        let error = await #expect(throws: AppLifecycleError.self) {
            _ = try await setup.backend.installBundle(bundle, as: Self.app, on: Self.phone) { _ in }
        }

        #expect(error?.kind == .notProvisioned)
        #expect(error?.message.contains(says) == true && error?.message.contains("Nothing was sent") == true, "\(error?.message ?? "")")
        #expect(error?.message.contains("00008130-0000000000000DEF") == false, "another device in the profile is never printed")
        #expect(setup.deviceCalls.isEmpty)
        #expect(setup.fixture.clones.isEmpty)
    }

    @Test("a profile that lists the device, and one that cannot be read, both go to the device, which stays the judge", arguments: [
        "app-profile-lists-device.mobileprovision", nil,
    ] as [String?])
    func profileAccepted(fixtureName: String?) async throws {
        let setup = try Setup(["apps": Self.noCopy, "install app": Self.installed(Self.app)])
        defer { setup.fixture.remove() }
        let profile = try fixtureName.map { try IOSDeviceFixtures.data($0) } ?? Data("not a profile".utf8)

        _ = try await setup.backend.installBundle(try setup.bundle(profile: profile), as: Self.app, on: Self.phone) { _ in }

        #expect(setup.installs.count == 1)
    }

    @Test("a profile's device list reads from its CMS envelope")
    func readsCoverage() throws {
        let coverage = try #require(ProvisioningProfile.coverage(of: try IOSDeviceFixtures.data("app-profile-lists-device.mobileprovision")))
        #expect(coverage.ProvisionedDevices == [IOSDeviceFixtures.phone] && coverage.ProvisionsAllDevices == nil)
        #expect(ProvisioningProfile.coverage(of: Data("plain".utf8)) == nil)
    }

    @Test("the profile check passes every device for an enterprise profile, any letter case of the UDID, and refuses an App Store profile")
    func coverageRules() {
        let later = Date(timeIntervalSince1970: 4_000_000_000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func refusal(devices: [String]?, all: Bool?, expires: Date? = later) -> AppLifecycleError? {
            AppProvisioning.refusal(.init(ExpirationDate: expires, ProvisionedDevices: devices, ProvisionsAllDevices: all), udid: IOSDeviceFixtures.phone, bundle: "Example.app", now: now)
        }
        #expect(refusal(devices: nil, all: true) == nil)
        #expect(refusal(devices: [IOSDeviceFixtures.phone.lowercased()], all: nil) == nil)
        #expect(refusal(devices: [IOSDeviceFixtures.phone], all: nil, expires: nil) == nil)
        #expect(refusal(devices: nil, all: nil)?.message.contains("signed for the App Store") == true)
        #expect(refusal(devices: [IOSDeviceFixtures.phone], all: nil, expires: now)?.kind == .notProvisioned)
        #expect(AppProvisioning.refusal(nil, udid: IOSDeviceFixtures.phone, bundle: "Example.app", now: now) == nil)
    }

    @Test("a nested extension from another app is refused on the Mac with no call to the device")
    func foreignExtension() async throws {
        let setup = try Setup(["apps": Self.noCopy, "install app": Self.installed(Self.app)])
        defer { setup.fixture.remove() }
        let bundle = try setup.bundle(nested: ["PlugIns/Share.appex": "com.example.other.share"])

        let error = await #expect(throws: AppLifecycleError.self) {
            _ = try await setup.backend.installBundle(bundle, as: Self.app, on: Self.phone) { _ in }
        }

        #expect(error?.kind == .packageMismatch)
        #expect(setup.deviceCalls.isEmpty && setup.fixture.clones.isEmpty)
    }

    @Test("a device on Wi-Fi is refused before the bundle is copied or anything is sent")
    func notWired() async throws {
        let fixture = try AppBundleFixture()
        defer { fixture.remove() }
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json")
        let backend = IOSDeviceBackend(host: IOSDeviceHost.fake(devicectl, usbmux: FakeUsbmuxListing([]), privateRoot: fixture.privateRoot)) { _, _ in }
        backend.pinPolicy = { _ in nil }
        let bundle = try AppBundle.read(try fixture.app(), for: .device)

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await backend.installBundle(bundle, as: Self.app, on: Self.phone) { _ in } }

        #expect(error?.kind == .notWired)
        #expect(devicectl.calls.isEmpty && fixture.clones.isEmpty)
    }

    @Test("uninstall removes an installed app with exactly these arguments, after the caller saw the copy")
    func uninstalls() async throws {
        let setup = try Setup(["apps": Self.copy(developer: true), "uninstall app": Self.reply("{}")])
        defer { setup.fixture.remove() }
        var seen: [InstalledAppCopy] = []

        let result = try await setup.backend.removeBundle(Self.app, on: Self.phone) { seen.append($0) }

        #expect(result == AppUninstall(app: Self.app, wasInstalled: true))
        #expect(seen == [InstalledAppCopy(app: Self.app, builtByDeveloper: true)])
        #expect(setup.uninstalls == [["device", "uninstall", "app", "--device", IOSDeviceFixtures.phone, Self.app, "--timeout", "30", "--json-output", "-", "-q"]])
    }

    @Test("uninstalling an app that is not there is no error and sends no uninstall; a caller that stops sends none either")
    func uninstallSendsNothing() async throws {
        let absent = try Setup(["apps": Self.noCopy])
        defer { absent.fixture.remove() }
        #expect(try await absent.backend.removeBundle(Self.app, on: Self.phone) { _ in Issue.record("there is no copy") } == AppUninstall(app: Self.app, wasInstalled: false))
        #expect(absent.uninstalls.isEmpty)

        let stopped = try Setup(["apps": Self.copy(developer: false)])
        defer { stopped.fixture.remove() }
        await #expect(throws: Stopped.self) { _ = try await stopped.backend.removeBundle(Self.app, on: Self.phone) { _ in throw Stopped() } }
        #expect(stopped.uninstalls.isEmpty)
    }

    @Test("a refused uninstall says what the device said")
    func uninstallRefused() async throws {
        let setup = try Setup(["apps": Self.copy(developer: true), "uninstall app": Self.refused("The app could not be removed.")])
        defer { setup.fixture.remove() }
        let error = await #expect(throws: AppLifecycleError.self) { _ = try await setup.backend.removeBundle(Self.app, on: Self.phone) { _ in } }
        #expect(error?.kind == .failed && error?.message.contains("The app could not be removed.") == true)
    }

    @Test("the installed ids read from either key devicectl has used, and from nothing else")
    func installedIDs() {
        #expect(DevicectlAppInstall.installedIDs(Data(Self.installed("com.example.a", "com.example.b").stdout.utf8)) == ["com.example.a", "com.example.b"])
        #expect(DevicectlAppInstall.installedIDs(Data(#"{"result":{"installedApplications":[{"bundleIdentifier":"com.example.a"}]}}"#.utf8)) == ["com.example.a"])
        for text in ["", "not json", #"{"result":{}}"#, #"{"result":{"installedApplications":[]}}"#, #"{"result":{"installedApplications":[{"bundleID":""}]}}"#] {
            #expect(DevicectlAppInstall.installedIDs(Data(text.utf8)) == nil, "\(text)")
        }
    }
}
