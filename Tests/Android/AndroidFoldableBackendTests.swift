import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android foldables and displays")
@MainActor
struct AndroidFoldableBackendTests {
    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    /// A foldable's shell: the hinge (moved by gRPC `setPosture` when there is an endpoint) sets the base state,
    /// and `cmd device_state state <id>` overrides it, as Android does.
    final class Fold: @unchecked Sendable {
        private let lock = NSLock()
        private let emulator: FakeEmulator?
        private var hinge: Int
        private var override: Int?
        private var lagging = 0

        init(emulator: FakeEmulator?, closed: Bool) {
            self.emulator = emulator
            hinge = closed ? 0 : 2
            emulator?.postureNow = closed ? .closed : .opened
        }

        var overrideState: Int? { lock.withLock { override } }

        /// The next `count` display probes still describe the panel the fold is leaving, as `wm size` and the viewport do on the device.
        func lagProbes(_ count: Int) { lock.withLock { lagging = count } }

        private var base: Int {
            guard let emulator else { return hinge }
            switch emulator.postureNow {
            case .closed?: return 0
            case .halfOpened?: return 1
            default: return 2
            }
        }

        private var committed: Int { override ?? base }

        func reply(to service: String) -> FakeAdbServer.Reply {
            lock.withLock {
                let command = service.hasPrefix("shell,v2,raw:") ? String(service.dropFirst("shell,v2,raw:".count)) : service
                let closed = committed == 0
                switch command {
                case AndroidDeviceState.printStates:
                    return FakeAdbServer.shell(stdout: FoldableFixtures.foldPrintStates)
                case AndroidDeviceState.readState:
                    return FakeAdbServer.shell(stdout: FoldableFixtures.foldState(committed: committed, base: base, override: override))
                case AndroidDeviceState.resetState:
                    override = nil
                    return FakeAdbServer.shell()
                case AndroidDisplayList.command:
                    return FakeAdbServer.shell(stdout: FoldableFixtures.foldDumpsys(closed: closed))
                case AndroidDisplayStatus.script:
                    return FakeAdbServer.shell(stdout: FoldableFixtures.status(
                        FoldableFixtures.foldPrintStates,
                        FoldableFixtures.foldState(committed: committed, base: base, override: override),
                        FoldableFixtures.foldDumpsys(closed: closed)
                    ))
                case AndroidDisplayGeometry.probeScript where lagging > 0:
                    lagging -= 1
                    return FakeAdbServer.shell(stdout: closed ? FoldableFixtures.foldGeometryOpen : FoldableFixtures.foldGeometryUnfolding)
                case AndroidDisplayGeometry.probeScript:
                    return FakeAdbServer.shell(stdout: FoldableFixtures.foldGeometry(closed: closed))
                case AndroidDeviceDirectory.propertiesScript:
                    return FakeAdbServer.shell(stdout: "Offsider_E2E_Pixel_9_Pro_Fold\n\n1\n16\n36\n")
                default:
                    if command.hasPrefix("cmd device_state state "), let id = Int(command.dropFirst("cmd device_state state ".count)) {
                        override = id
                        return FakeAdbServer.shell()
                    }
                    return FakeAdbServer.shell()
                }
            }
        }
    }

    struct Rig {
        let backend: AndroidBackend
        let server: FakeAdbServer
        let emulator: FakeEmulator?
        let fold: Fold
        let sleeps: SleepRecorder

        var shellCommands: [String] {
            server.services.filter { $0.hasPrefix("shell,v2,raw:") }.map { String($0.dropFirst("shell,v2,raw:".count)) }
        }
    }

    /// With `grpc`, a live discovery file and a fake endpoint; without, no discovery file, so adb drives it.
    static func rig(grpc: Bool, closed: Bool = false, frames: [EmulatorFrame] = []) throws -> Rig {
        let emulator = grpc ? FakeEmulator(frames: frames) : nil
        let fold = Fold(emulator: emulator, closed: closed)
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in fold.reply(to: service) }
        ))
        let home = try AndroidTestHost.homeWithSDK()
        var connector = FakeEmulatorConnector.refusing
        var live: Set<Int32> = []
        if let emulator {
            try AndroidTestHost.write(
                "avd.id=Offsider_E2E_Pixel_9_Pro_Fold\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n",
                to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
                in: home
            )
            connector = FakeEmulatorConnector(.success(emulator))
            live = [50144]
        }
        let sleeps = SleepRecorder()
        let host = AndroidTestHost.make(home: home, adb: server, emulator: connector, liveProcesses: live, sleeps: sleeps)
        return Rig(backend: AndroidBackend(host: host) { _, _ in }, server: server, emulator: emulator, fold: fold, sleeps: sleeps)
    }

    @Test("closing over gRPC sends setPosture, then device_state reports CLOSED and the screen is the cover's")
    func closeOverGrpc() async throws {
        let rig = try Self.rig(grpc: true)
        #expect(try await rig.backend.posture(of: Self.device) == .open)
        let open = try #require(try await rig.backend.screenInfo(for: Self.device))
        #expect(open.display == ScreenDisplay(id: "inner", platformId: FoldableFixtures.innerId))
        #expect((open.width, open.height) == (851.69, 882.87))

        try await rig.backend.requestPosture(.closed, on: Self.device)

        #expect(rig.emulator?.calls.contains(.setPosture(.closed)) == true)
        #expect(!rig.shellCommands.contains { $0.hasPrefix("cmd device_state state ") && $0 != AndroidDeviceState.readState })
        #expect(try await rig.backend.posture(of: Self.device) == .closed)
        let closed = try #require(try await rig.backend.screenInfo(for: Self.device))
        #expect(closed.display == ScreenDisplay(id: "cover", platformId: FoldableFixtures.coverId))
        #expect(closed.posture == .closed)
        #expect((closed.width, closed.height) == (443.08, 994.46))
        #expect(rig.shellCommands.filter { $0 == AndroidDisplayGeometry.probeScript }.count == 2)
    }

    @Test("after a fold, the screen size follows the new panel even while the display probe still describes the old one")
    func screenFollowsPanelSwap() async throws {
        let rig = try Self.rig(grpc: false, closed: true)
        let closed = try #require(try await rig.backend.screenInfo(for: Self.device))
        #expect((closed.width, closed.height) == (443.08, 994.46))

        try await rig.backend.requestPosture(.open, on: Self.device)
        rig.fold.lagProbes(2)
        let open = try #require(try await rig.backend.screenInfo(for: Self.device))

        #expect(open.display == ScreenDisplay(id: "inner", platformId: FoldableFixtures.innerId))
        #expect((open.width, open.height) == (851.69, 882.87))
        #expect(rig.sleeps.sleeps.count == 2)

        try await rig.backend.requestPosture(.closed, on: Self.device)
        rig.fold.lagProbes(1)
        let refolded = try #require(try await rig.backend.screenInfo(for: Self.device))
        #expect(refolded.display == ScreenDisplay(id: "cover", platformId: FoldableFixtures.coverId))
        #expect((refolded.width, refolded.height) == (443.08, 994.46))
    }

    @Test("a display probe that never catches up is used after 10 s rather than waiting on")
    func settleGivesUp() async throws {
        let rig = try Self.rig(grpc: false, closed: true)
        try await rig.backend.requestPosture(.open, on: Self.device)
        rig.fold.lagProbes(1000)

        let screen = try #require(try await rig.backend.screenInfo(for: Self.device))

        #expect((screen.width, screen.height) == (443.08, 994.46))
        #expect(rig.sleeps.total >= .seconds(10) && rig.sleeps.total < .seconds(11))
    }

    @Test("after unfolding, gRPC taps reach the inner panel's far side instead of clamping to the cover the probe still described")
    func unfoldedTapUsesNewPanel() async throws {
        let rig = try Self.rig(grpc: true, closed: true)
        _ = try await rig.backend.screenInfo(for: Self.device)
        try await rig.backend.requestPosture(.open, on: Self.device)
        rig.fold.lagProbes(1)

        try await rig.backend.perform(.tapAt(x: 1950, y: 244), on: Self.device)

        let touches = rig.emulator?.calls.compactMap { call -> PanelTouch? in
            if case .touch(let touch) = call { return touch } else { return nil }
        } ?? []
        #expect(touches.first.map { ($0.x, $0.y) } ?? (0, 0) == (1950, 244))
    }

    @Test("an unfolded foldable whose probe fits its panel reads the screen without waiting")
    func settledFoldNeverWaits() async throws {
        let rig = try Self.rig(grpc: false)
        _ = try await rig.backend.screenInfo(for: Self.device)
        #expect(rig.sleeps.sleeps.isEmpty)
    }

    @Test("an adb override left on the device is reset before gRPC moves the hinge")
    func grpcResetsOverride() async throws {
        let rig = try Self.rig(grpc: true)
        _ = rig.fold.reply(to: "shell,v2,raw:cmd device_state state 0")

        try await rig.backend.requestPosture(.open, on: Self.device)

        #expect(rig.shellCommands.contains(AndroidDeviceState.resetState))
        #expect(rig.emulator?.calls.contains(.setPosture(.opened)) == true)
        #expect(try await rig.backend.posture(of: Self.device) == .open)
    }

    @Test("without gRPC, the posture is a device_state override, and returning to the hinge's state resets it")
    func adbFallback() async throws {
        let rig = try Self.rig(grpc: false)

        try await rig.backend.requestPosture(.closed, on: Self.device)
        #expect(rig.shellCommands.contains("cmd device_state state 0"))
        #expect(try await rig.backend.posture(of: Self.device) == .closed)

        try await rig.backend.requestPosture(.open, on: Self.device)
        #expect(rig.shellCommands.contains(AndroidDeviceState.resetState))
        #expect(rig.fold.overrideState == nil)
        #expect(try await rig.backend.posture(of: Self.device) == .open)
    }

    @Test("the displays of a closed foldable: the cover active and turned, the inner off at its native size")
    func foldDisplays() async throws {
        let rig = try Self.rig(grpc: false, closed: true)
        let list = try await rig.backend.displays(of: Self.device)

        #expect(list.posture == .closed)
        #expect(list.active?.descriptor.role == .cover)
        #expect(list.active?.rotationDegrees == 0)
        let inner = try list.resolve("inner", device: "emulator-5556")
        #expect(!inner.active)
        #expect(inner.rotationDegrees == nil)
        #expect((inner.pointWidth, inner.pointHeight) == (2076 / 2.4375, 2152 / 2.4375))
    }

    @Test("capturing a display by id is screencap -d, and one that is off says how to turn it on")
    func displayCapture() async throws {
        let png = try AndroidScreenCapture.encodePNG(.init(width: 1, height: 1, bytes: Data([1, 2, 3, 255])))
        let fold = Fold(emulator: nil, closed: true)
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in
                service == "exec:screencap -d \(FoldableFixtures.coverId) -p" ? FakeAdbServer.exec(png) : fold.reply(to: service)
            }
        ))
        let backend = try AndroidBackendTests.backend(server)

        #expect(try await backend.screenshotPNG(for: Self.device, display: FoldableFixtures.coverId) == png)
        let off = await #expect(throws: AndroidError.self) {
            try await backend.screenshotPNG(for: Self.device, display: FoldableFixtures.innerId)
        }
        #expect(off?.message == "The inner display (\(FoldableFixtures.innerId)) of emulator-5556 is off (posture closed), so it has nothing to capture. Unfold the emulator with `offsider posture open --device emulator-5556`, then retry.")
        let unknown = await #expect(throws: AndroidError.self) {
            try await backend.screenshotPNG(for: Self.device, display: "0")
        }
        #expect(unknown?.message == "Unknown display '0' on emulator-5556. Use one of: inner (\(FoldableFixtures.innerId)), cover (\(FoldableFixtures.coverId)).")
    }

    @Test("a folded gRPC screenshot is cropped to the folded view")
    func foldedScreenshot() async throws {
        let frame = EmulatorFrame(format: .rgba8888, width: 4, height: 2, emulatorRotation: 0, sequence: 1, bytes: Data(count: 32))
        let rig = try Self.rig(grpc: true, closed: true, frames: [frame])
        rig.emulator?.folded = FoldedRect(x: 1, y: 0, width: 2, height: 2)

        let png = try await rig.backend.screenshotPNG(for: Self.device)
        #expect(try AndroidScreenCaptureTests.labels(ofPNG: png).width == 2)
    }

    @Test("while folded, taps go over adb, not gRPC")
    func foldedInputOverAdb() async throws {
        let rig = try Self.rig(grpc: true, closed: true)
        try await rig.backend.perform(.tapAt(x: 100, y: 200), on: Self.device)

        #expect(rig.emulator?.calls.contains { if case .touch = $0 { return true } else { return false } } == false)
        #expect(rig.shellCommands.contains { $0.contains("input") })
    }

    @Test("setting a physical foldable's posture is refused before any adb call; reading it works")
    func physicalFoldable() async throws {
        let fold = Fold(emulator: nil, closed: false)
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["R58M123ABC"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in fold.reply(to: service) }
        ))
        let backend = AndroidBackend(host: AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)) { _, _ in }
        let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)

        #expect(try await backend.posture(of: phone) == .open)
        let before = server.requests.count
        let error = await #expect(throws: AndroidError.self) { try await backend.requestPosture(.closed, on: phone) }
        #expect(error?.kind == .unsupportedDevice)
        #expect(error?.message.contains("Fold the phone by hand") == true)
        #expect(server.requests.count == before)
        #expect(fold.overrideState == nil)
    }

    @Test("a phone is not foldable: no posture, one main display named by its physical id")
    func phone() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in
                switch String(service.dropFirst("shell,v2,raw:".count)) {
                case AndroidDeviceState.printStates: return FakeAdbServer.shell(stdout: FoldableFixtures.pixel9PrintStates)
                case AndroidDisplayList.command: return FakeAdbServer.shell(stdout: FoldableFixtures.pixel9Dumpsys)
                case AndroidDisplayStatus.script:
                    return FakeAdbServer.shell(stdout: FoldableFixtures.status(FoldableFixtures.pixel9PrintStates, FoldableFixtures.pixel9State, FoldableFixtures.pixel9Dumpsys))
                case AndroidDisplayGeometry.probeScript: return FakeAdbServer.shell(stdout: FoldableFixtures.pixel9Geometry)
                default: return FakeAdbServer.shell(stderr: "unexpected", status: 1)
                }
            }
        ))
        let backend = try AndroidBackendTests.backend(server)

        #expect(try await backend.posture(of: Self.device) == nil)
        let screen = try #require(try await backend.screenInfo(for: Self.device))
        #expect(screen.display == ScreenDisplay(id: "main", platformId: FoldableFixtures.pixel9Id))
        #expect(screen.posture == nil)
        #expect(screen.rotationDegrees == 0)
        #expect(server.services.filter { $0.hasPrefix("shell,v2,raw:") } == [
            "shell,v2,raw:\(AndroidDeviceState.printStates)",
            "shell,v2,raw:\(AndroidDisplayGeometry.probeScript)",
        ])

        let list = try await backend.displays(of: Self.device)
        #expect(list.posture == nil)
        #expect(list.displays.count == 1)
        #expect(list.active.map { ($0.pointWidth, $0.pointHeight) } ?? (0, 0) == (411.43, 923.43))
        let error = await #expect(throws: AndroidError.self) { try await backend.requestPosture(.closed, on: Self.device) }
        #expect(error?.kind == .postureUnavailable)
    }

    @Test("a command's first screen read adds one shell call for the display and posture, and later reads none")
    func screenStatusOnce() async throws {
        let rig = try Self.rig(grpc: false, closed: true)
        _ = try await rig.backend.screenInfo(for: Self.device)
        _ = try await rig.backend.screenInfo(for: Self.device)

        #expect(rig.shellCommands.filter { $0 == AndroidDisplayStatus.script }.count == 1)
    }

    @Test("a folded foldable's screen JSON names the cover display and the closed posture")
    func foldedScreenJSON() async throws {
        let rig = try Self.rig(grpc: false, closed: true)
        let screen = try #require(try await rig.backend.screenInfo(for: Self.device))
        let text = String(decoding: UITreeRenderer.render(
            UITree(platform: .android, device: "emulator-5556", screen: screen, roots: []),
            UITreeRenderOptions(compact: true)
        ), as: UTF8.self)
        #expect(text.contains(#""screen":{"width":443.08,"height":994.46,"scale":2.4375,"orientation":"portrait","rotation":0,"display":{"id":"cover","platformId":"\#(FoldableFixtures.coverId)"},"posture":"closed"}"#))
    }

    @Test("on a landscape-natural panel, rotation 0 is landscape and portrait is user_rotation 3 at rotation 0")
    func landscapeNatural() async throws {
        final class Panel: @unchecked Sendable {
            let lock = NSLock()
            var rotation = 0
        }
        let panel = Panel()
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in
                let command = String(service.dropFirst("shell,v2,raw:".count))
                if command == AndroidDisplayGeometry.probeScript {
                    let rotation = panel.lock.withLock { panel.rotation }
                    let frame = rotation % 2 == 1 ? "1840, 2208" : "2208, 1840"
                    return FakeAdbServer.shell(stdout: """
                    Physical size: 2208x1840
                    Physical density: 420
                      Viewport INTERNAL: displayId=0, uniqueId=local:1, port=Optional(0), orientation=\(rotation), logicalFrame=[0, 0, \(frame)], isActive=[1]
                    """)
                }
                if command.hasPrefix("settings put system accelerometer_rotation 0; settings put system user_rotation "), let rotation = Int(command.suffix(1)) {
                    panel.lock.withLock { panel.rotation = rotation }
                }
                return FakeAdbServer.shell()
            }
        ))
        let backend = try AndroidBackendTests.backend(server)

        #expect(try await backend.orientation(of: Self.device) == .landscapeLeft)
        try await backend.requestOrientation(.portrait, on: Self.device)
        #expect(server.services.contains("shell,v2,raw:settings put system accelerometer_rotation 0; settings put system user_rotation 3"))
        #expect(try await backend.orientation(of: Self.device) == .portrait)
        #expect(try await backend.screenInfo(for: Self.device)?.rotationDegrees == 0)
    }
}
