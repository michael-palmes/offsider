import Foundation
import OffsiderCore
@testable import Offsider
@testable import OffsiderIOSDevice
import Testing

@Suite("iPhone and iPad app results")
@MainActor
struct IOSDeviceAppLifecycleTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)
    static let app = "com.mpalmes.offsider.playground"
    static let appDir = "file:///private/var/containers/Bundle/Application/00000000-0000-4000-8000-000000000001/OffsiderPlayground.app"
    static let plugin = "\(appDir)/PlugIns/Widget.appex/Widget"
    static let main = "\(appDir)/OffsiderPlayground"

    static func reply(_ result: String) -> ProcessCaptureResult {
        ProcessCaptureResult(status: 0, stdout: #"{"info":{"outcome":"success"},"result":\#(result)}"#, stderr: "")
    }

    static func apps(url: Bool = true) -> ProcessCaptureResult {
        reply(#"{"apps":[{"bundleIdentifier":"\#(app)","name":"Offsider Playground"\#(url ? #","url":"\#(appDir)/""# : "")}]}"#)
    }

    static func processes(_ rows: [(String, Int)]) -> ProcessCaptureResult {
        let list = rows.map { #"{"executable":"\#($0.0)","processIdentifier":\#($0.1)}"# }.joined(separator: ",")
        return reply(#"{"runningProcesses":[\#(list)]}"#)
    }

    static let launched = reply(#"{"process":{"processIdentifier":4021}}"#)

    static func setUp(_ extra: [String: ProcessCaptureResult]) throws -> (IOSDeviceBackend, FakeDevicectl) {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json", extra: extra)
        let backend = IOSDeviceBackend(host: IOSDeviceHost.fake(devicectl, usbmux: FakeUsbmuxListing.onUSB(IOSDeviceFixtures.phone))) { _, _ in }
        return (backend, devicectl)
    }

    static func terminations(_ devicectl: FakeDevicectl) -> [[String]] {
        devicectl.calls.filter { $0.starts(with: ["device", "process", "terminate"]) }
    }

    @Test("stop ends the app's own process, not an extension listed before it")
    func stopSkipsExtension() async throws {
        let (backend, devicectl) = try Self.setUp(["apps": Self.apps(), "processes": Self.processes([(Self.plugin, 70), (Self.main, 4021)]), "terminate": Self.reply("{}")])
        #expect(try await backend.terminateApp(Self.app, on: Self.phone).wasRunning == true)
        let call = try #require(Self.terminations(devicectl).first)
        #expect(call.contains("4021") && !call.contains("70"))
    }

    @Test("with only an extension running the app was not running, and nothing is terminated")
    func stopExtensionOnly() async throws {
        let (backend, devicectl) = try Self.setUp(["apps": Self.apps(), "processes": Self.processes([(Self.plugin, 70)])])
        #expect(try await backend.terminateApp(Self.app, on: Self.phone).wasRunning == false)
        #expect(Self.terminations(devicectl).isEmpty)
    }

    @Test("a launch reads a running app as warm past an extension's row, and an extension alone as a cold start", arguments: [
        ([(Self.plugin, 70), (Self.main, 4021)], AppStart.warm),
        ([(Self.plugin, 70)], AppStart.cold),
    ])
    func launchReadsTheApp(rows: [(String, Int)], start: AppStart) async throws {
        let (backend, _) = try Self.setUp(["apps": Self.apps(), "processes": Self.processes(rows), "launch": Self.launched])
        #expect(try await backend.launchApp(Self.app, restart: false, on: Self.phone).start == start)
    }

    @Test("with no bundle location stop says so and sends nothing, rather than reporting the app was not running")
    func stopWithoutBundleLocation() async throws {
        let (backend, devicectl) = try Self.setUp(["apps": Self.apps(url: false)])
        let error = await #expect(throws: AppLifecycleError.self) { _ = try await backend.terminateApp(Self.app, on: Self.phone) }
        #expect(error?.kind == .failed)
        #expect(error?.message.contains("stopped nothing") == true)
        #expect(Self.terminations(devicectl).isEmpty)
    }

    @Test("with no bundle location a launch names no start kind, rather than calling it cold")
    func launchWithoutBundleLocation() async throws {
        let (backend, _) = try Self.setUp(["apps": Self.apps(url: false), "launch": Self.launched])
        let launch = try await backend.launchApp(Self.app, restart: false, on: Self.phone)
        #expect(launch.start == nil)
        #expect(launch.pid == 4021)
    }

    @Test("a delivered link says sent, not opened, as devicectl reports no more")
    func openOnlyDelivers() async throws {
        let (backend, _) = try Self.setUp(["apps": Self.apps(), "processes": Self.processes([]), "launch": Self.launched])
        let launch = try await backend.openLink("offsiderplayground://screen/x", in: Self.app, restart: false, on: Self.phone)
        #expect(launch.linkHandled == nil)
        #expect(AppOpenCommand.verb(launch) == "Sent the link to")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(AppReport.launch(launch, action: "open", url: "a://b", on: Self.phone).utf8)) as? [String: Any])
        #expect(object["linkHandled"] is NSNull)
    }

    @Test("a platform that saw the app take the link says opened, in text and JSON")
    func openHandled() throws {
        let launch = AppLaunch(app: Self.app, start: .cold, restarted: false, linkHandled: true)
        #expect(AppOpenCommand.verb(launch) == "Opened the link in")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(AppReport.launch(launch, action: "open", url: "a://b", on: Self.phone).utf8)) as? [String: Any])
        #expect(object["linkHandled"] as? Bool == true)
        let launched = try #require(try JSONSerialization.jsonObject(with: Data(AppReport.launch(launch, action: "launch", on: Self.phone).utf8)) as? [String: Any])
        #expect(launched["linkHandled"] == nil)
    }

    @Test("a failure that says the device is locked is device_locked, and keeps devicectl's words", arguments: ["The device is locked.", "Unable to launch: device must be unlocked first", "LOCKED"])
    func lockedLine(_ line: String) async throws {
        let (backend, _) = try Self.setUp(["apps": ProcessCaptureResult(status: 1, stdout: "", stderr: line)])
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await backend.appInfo(Self.app, on: Self.phone) }
        #expect(error?.kind == .locked)
        #expect(error?.message.contains(line) == true)
    }

    @Test("blocked, or a name holding the letters, is not locked: the real failure comes through", arguments: ["launch was blocked by policy", "cannot launch com.example.locked", "unblocked"])
    func notLocked(_ line: String) async throws {
        let (backend, _) = try Self.setUp(["apps": ProcessCaptureResult(status: 1, stdout: "", stderr: line)])
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await backend.appInfo(Self.app, on: Self.phone) }
        #expect(error?.kind == .devicectlFailed)
        #expect(error?.message.contains(line) == true)
    }
}
