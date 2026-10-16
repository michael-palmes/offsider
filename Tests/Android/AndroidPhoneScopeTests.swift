import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// The per-app checks on an allowed Android phone: what is in front, which window is active, and when the check runs again.
@Suite("Android phone app scope")
@MainActor
struct AndroidPhoneScopeTests {
    static let phone = AndroidBackendHelperTests.phone
    static let playground = "com.mpalmes.offsider.playground.rn"

    /// A phone whose front app is the playground, answering the display probe so input can be sent.
    static func drivablePhone() throws -> (AndroidBackend, FakeAdbServer) {
        let server = AndroidDeviceStateTests.server(devicesList: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n") { command in
            if command == AndroidForeground.readScript {
                return FakeAdbServer.shell(stdout: "top=  topResumedActivity=ActivityRecord{1a2b u0 \(Self.playground)/.MainActivity t12}\nhome=com.example.launcher/.Home\n")
            }
            if command.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
            return FakeAdbServer.shell()
        }
        return (try AndroidBackendTests.backend(server), server)
    }

    static let shade = #"{"id":2400,"type":"system","layer":5,"title":"Notification shade","displayId":0,"bounds":[0,0,1080,2424],"active":true,"focused":true,"root":{"i":9,"class":"android.widget.FrameLayout","package":"com.android.systemui","bounds":[0,0,1080,2424],"children":[]}}"#

    static func tree(_ windows: String) throws -> UITree {
        let dump = try HelperTreeMappingTests.dump(windows)
        var tree = UITree(platform: .android, device: phone.rawValue, roots: HelperTreeMapping.roots(from: dump, scale: HelperTreeMappingTests.scale, pid: 1).roots)
        tree.windows = HelperTreeMapping.windows(from: dump, scale: HelperTreeMappingTests.scale)
        return tree
    }

    @Test("each input step on a phone reads the front app again, and a capture after input reads it too; captures alone share one read")
    func recheckPerStep() async throws {
        let (backend, server) = try Self.drivablePhone()
        let session = try await backend.openInputSession(for: Self.phone)
        try await session.perform(.shortKeyPress(4))
        try await session.perform(.shortKeyPress(5))
        #expect(AndroidBackendHelperTests.foregroundReads(server) == 2)

        _ = try? await backend.screenshotPNG(for: Self.phone)
        #expect(AndroidBackendHelperTests.foregroundReads(server) == 3)
        _ = try? await backend.screenshotPNG(for: Self.phone)
        #expect(AndroidBackendHelperTests.foregroundReads(server) == 3)
    }

    @Test("a second step is refused once another app comes to the front, though the first step passed")
    func laterStepRefused() async throws {
        let front = LockedBox("\(Self.playground)/.MainActivity")
        let server = AndroidDeviceStateTests.server(devicesList: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n") { command in
            if command == AndroidForeground.readScript {
                return FakeAdbServer.shell(stdout: "top=  topResumedActivity=ActivityRecord{1a2b u0 \(front.value) t12}\nhome=com.example.launcher/.Home\n")
            }
            if command.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
            return FakeAdbServer.shell()
        }
        let backend = try AndroidBackendTests.backend(server)
        let session = try await backend.openInputSession(for: Self.phone)
        try await session.perform(.shortKeyPress(4))
        front.value = "com.android.chrome/com.google.android.apps.chrome.Main"
        let error = await #expect(throws: AndroidError.self) { try await session.perform(.shortKeyPress(5)) }
        #expect(error?.reason == .appNotAllowed)
        #expect(server.services.filter { $0.contains("input keyevent") }.count == 1)
    }

    @Test("the notification shade open over an allowed app is refused; the app's own dialog is not")
    func activeWindow() throws {
        let (backend, server) = try AndroidBackendHelperTests.phoneBackend(top: "\(Self.playground)/.MainActivity")
        backend.appScopes[Self.phone.rawValue] = AndroidAppScope(permitted: [Self.playground], managedCeiling: nil)
        let app = HelperTreeMappingTests.appWindow(HelperTreeMappingTests.switchChildren, active: false)

        let shaded = try Self.tree(app + "," + Self.shade)
        let error = #expect(throws: AndroidError.self) { try backend.requireDrivableWindows(shaded, on: Self.phone.rawValue) }
        #expect(error?.reason == .appNotAllowed)
        #expect(error?.message.contains("com.android.systemui") == true)

        let dialog = #"{"id":2401,"type":"application","layer":2,"title":"Delete item?","displayId":0,"bounds":[60,800,1020,1400],"active":true,"focused":true,"root":{"i":20,"class":"android.widget.FrameLayout",\#(HelperTreeMappingTests.package),"bounds":[60,800,1020,1400],"children":[]}}"#
        try backend.requireDrivableWindows(try Self.tree(app + "," + dialog), on: Self.phone.rawValue)
        try backend.requireDrivableWindows(shaded, on: "emulator-5556")
        #expect(AndroidBackendHelperTests.foregroundReads(server) == 0)
    }

    @Test("the windows carry each root's package and bounds in dp, for masking system windows in a capture")
    func windowFields() throws {
        let tree = try Self.tree(HelperTreeMappingTests.appWindow(HelperTreeMappingTests.switchChildren, active: false) + "," + Self.shade)
        let shade = try #require(tree.windows?.first { $0.package == "com.android.systemui" })
        #expect(shade.kind == "system")
        #expect(shade.active)
        #expect(shade.bounds == UIFrame(x: 0, y: 0, width: 1080 / HelperTreeMappingTests.scale, height: 2424 / HelperTreeMappingTests.scale))
        #expect(AndroidBackend.activeWindowPackages(tree) == ["com.android.systemui"])
    }

    @Test("without a window list the uiautomator root's package is checked")
    func uiautomatorRoot() throws {
        let roots = AndroidTreeMapping.roots(from: try UIAutomatorDump.parse(HelperTreeMappingTests.switchXML), scale: HelperTreeMappingTests.scale)
        #expect(AndroidBackend.activeWindowPackages(UITree(platform: .android, device: "R58M123ABC", roots: roots)) == [Self.playground])
    }

    @Test("a phone allowed for any app drives only the app the command names, and refuses until one is named")
    func anyAppNeedsTarget() async throws {
        let (backend, _) = try AndroidBackendHelperTests.phoneBackend(top: "com.example.app/.MainActivity")
        backend.appScopes[Self.phone.rawValue] = AndroidAppScope(permitted: [], managedCeiling: nil, needsTarget: true)
        let unnamed = await #expect(throws: AndroidError.self) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
        #expect(unnamed?.reason == .appNotAllowed)
        #expect(unnamed?.message.contains("offsider.login.json") == true)

        backend.selectApp("com.example.other", on: Self.phone.rawValue)
        let other = await #expect(throws: AndroidError.self) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
        #expect(other?.message.contains("not com.example.other") == true)

        backend.selectApp("com.example.app", on: Self.phone.rawValue)
        try await backend.requireDrivableForeground(Self.phone.rawValue)
    }
}

/// A value tests change from the adb handler's thread.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
