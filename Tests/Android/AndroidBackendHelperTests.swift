import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android backend with the helper")
@MainActor
struct AndroidBackendHelperTests {
    static let device = HelperRig.device

    @Test("describe-ui makes one server check, one start shell and one socket: hello and dump, then quit on close")
    func describeUISequence() async throws {
        let rig = try HelperRig()
        try await rig.backend.prepare()
        let tree = try await rig.read()
        let info = try await rig.backend.screenInfo(for: Self.device)
        _ = try await rig.backend.deviceCoordinates(for: [(x: 10, y: 10)], tree: tree, on: Self.device)

        #expect(rig.server.services == [
            "host:version",
            "host:transport:emulator-5556", "shell,v2,raw:" + HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: nil),
            "host:transport:emulator-5556", "localabstract:offsider-fake-1",
        ])
        #expect(rig.device.ops == ["hello", "dump"])
        #expect(info == UIScreenInfo(width: 411.43, height: 923.43, scale: 2.625, rotation: .portrait))
        #expect(tree.roots.map(\.label) == ["OffsiderPlaygroundRN"])
        #expect(tree.roots.first?.children.map(\.id) == ["BackButton", "tap-count"])

        await rig.backend.close()

        #expect(rig.device.ops == ["hello", "dump", "quit"])
        #expect(rig.server.services.count == 5)
        #expect(rig.device.kills.isEmpty)
    }

    @Test("later reads in the command reuse the same helper")
    func reuse() async throws {
        let rig = try HelperRig()
        _ = try await rig.read()
        _ = try await rig.read()
        _ = try await rig.backend.accessibilityTree(for: Self.device, point: UIPoint(x: 20, y: 70))

        #expect(rig.startShells == 1)
        #expect(rig.device.ops == ["hello", "dump", "dump", "dump"])
        await rig.backend.close()
    }

    @Test("with a point, the deepest node there across the roots is the only root")
    func point() async throws {
        let rig = try HelperRig()
        let tree = try await rig.backend.accessibilityTree(for: Self.device, point: UIPoint(x: 20, y: 70))
        #expect(tree.roots.map(\.id) == ["BackButton"])
        await rig.backend.close()
    }

    static let noWindowDump = #"{"generation":1,"idle":true,\#(FakeHelperDevice.display),"windows":[\#(FakeHelperDevice.statusBar),{"id":1,"type":"application","layer":0,"title":"X","bounds":[0,0,1080,2424],"active":true,"focused":true,"root":null}],"truncated":false,"eventSeq":1}"#

    @Test("a dump with no window is read once more after 500 ms, then reported as transient so polling callers retry")
    func noWindow() async throws {
        let device = FakeHelperDevice()
        device.dump = Self.noWindowDump
        let rig = try HelperRig(device)

        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.kind == .noWindow)
        #expect(error?.message == "Offsider found no window on emulator-5556. Unlock the emulator and bring an app to the front.")
        #expect(error?.isTransientFailure == true)
        #expect(rig.device.ops.filter { $0 == "dump" }.count == 2)
        #expect(rig.sleeps.sleeps == [.milliseconds(500)])
        await rig.backend.close()
    }

    @Test("a window that appears by the second read gives the tree")
    func noWindowThenTree() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, json in op == "dump" && json.contains(#""id":2"#) ? .ok(Self.noWindowDump) : nil }
        let rig = try HelperRig(device)

        let tree = try await rig.read()

        #expect(tree.roots.first?.children.first?.id == "BackButton")
        await rig.backend.close()
    }

    static let busy = FakeHelperDevice.Start.exit(status: 4, stdout: HelperLauncherTests.busyJSON + "\n")

    @Test("busy with an Offsider helper that stays past 2 s names its pid and how to stop it, and kills nothing")
    func busyStaleHelper() async throws {
        let device = FakeHelperDevice(starts: [Self.busy])
        device.pidof = { _ in "4242\n" }
        let rig = try HelperRig(device)

        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.message == "An earlier Offsider helper (pid 4242) still holds UiAutomation on emulator-5556. It exits within 10 s of losing its command; to free it now, run `adb -s emulator-5556 shell kill 4242`.")
        #expect(rig.sleeps.total == .seconds(2))
        #expect(rig.device.kills.isEmpty)
        #expect(rig.startShells == 1)
    }

    @Test("busy with an Offsider helper that leaves within 2 s starts again once and reads the screen")
    func busyHelperLeaves() async throws {
        let device = FakeHelperDevice(starts: [Self.busy, .ready])
        device.pidof = { call in call == 1 ? "4242\n" : "" }
        let rig = try HelperRig(device)

        let tree = try await rig.read()

        #expect(tree.roots.first?.label == "OffsiderPlaygroundRN")
        #expect(rig.startShells == 2)
        #expect(rig.sleeps.sleeps == [.milliseconds(250)])
        await rig.backend.close()
    }

    @Test("busy with no Offsider helper running blames another UiAutomation client at once")
    func busyOtherTool() async throws {
        let rig = try HelperRig(FakeHelperDevice(starts: [Self.busy]))
        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.message == "Another UiAutomation client is connected to emulator-5556 (Appium, Maestro, uiautomator, an instrumentation test or Layout Inspector), so Offsider cannot read its screen. Stop that client, then retry.")
        #expect(rig.sleeps.sleeps.isEmpty)
    }

    @Test("a truncated dump warns once per command")
    func truncated() async throws {
        let device = FakeHelperDevice()
        device.dump = FakeHelperDevice.tapTestDump.replacingOccurrences(of: #""truncated":false"#, with: #""truncated":true"#)
        let rig = try HelperRig(device)
        _ = try await rig.read()
        _ = try await rig.read()

        #expect(rig.log.warnings == ["The screen on emulator-5556 has more than 20,000 accessibility nodes; describe-ui shows the first 20,000."])
        await rig.backend.close()
    }

    @Test("a resized display reported by the helper keeps input on adb, as the probe's override does")
    func resizedDisplay() async throws {
        let device = FakeHelperDevice()
        device.dump = FakeHelperDevice.tapTestDump.replacingOccurrences(of: #""logicalWidthPx":1080,"logicalHeightPx":2424"#, with: #""logicalWidthPx":720,"logicalHeightPx":1616"#)
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n",
            to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
            in: home
        )
        let emulator = FakeEmulator()
        let rig = try HelperRig(device, emulator: FakeEmulatorConnector(.success(emulator)), home: home)
        _ = try await rig.read()

        try await rig.backend.perform(.tapAt(x: 10, y: 20), on: Self.device)

        #expect(!emulator.calls.contains { if case .touch = $0 { return true } else { return false } })
        #expect(rig.log.warnings.contains("The display of emulator-5556 is resized (`wm size` reports an override), so its input goes over adb in this command."))
        #expect(!rig.server.services.contains { $0.hasSuffix(AndroidDisplayGeometry.probeScript) })
        await rig.backend.close()
    }
}
