import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// Commands on emulator-5556 that keep the helper warm in a `BrokerFixture`, reading the display status `status` names.
@MainActor
final class WarmScreenRig {
    let fixture: BrokerFixture
    let server: FakeAdbServer
    let home: URL

    init(status: String, probe: String) async throws {
        let device = FakeHelperDevice()
        device.other = { service in
            switch service.dropFirst("shell,v2,raw:".count) {
            case AndroidDisplayStatus.script: return FakeAdbServer.shell(stdout: status)
            case AndroidDisplayStatus.scriptWithProbe: return FakeAdbServer.shell(stdout: FoldableFixtures.withProbe(status, probe))
            case AndroidDisplayGeometry.probeScript: return FakeAdbServer.shell(stdout: probe)
            default: return FakeAdbServer.shell()
            }
        }
        fixture = BrokerFixture(device: device, idle: .seconds(HelperBrokerSettings.defaultIdleSeconds))
        try await fixture.start()
        server = device.server()
        home = try AndroidTestHost.homeWithSDK()
    }

    static let pixel9Status = FoldableFixtures.status(FoldableFixtures.pixel9PrintStates, FoldableFixtures.pixel9State, FoldableFixtures.pixel9Dumpsys)

    /// The display status shells run so far.
    var statusReads: Int {
        server.services.filter { $0.hasPrefix("shell,v2,raw:\(AndroidDisplayStatus.script)") }.count
    }

    /// One describe-ui: the status prefetched beside the tree read, then the screen, then close.
    func describe() async throws -> UIScreenInfo? {
        var host = AndroidTestHost.make(home: home, adb: server, liveProcesses: [50144], helperDex: FakeHelperDevice.dex)
        host.helperBroker = try fixture.brokerHost()
        let backend = AndroidBackend(host: host, log: { _, _ in })
        backend.prefetchScreenStatus(for: HelperRig.device)
        _ = try await backend.accessibilityTree(for: HelperRig.device, point: nil)
        let screen = try await backend.screenInfo(for: HelperRig.device)
        await backend.close()
        return screen
    }

    var keptFacts: WarmScreenFacts? {
        get async { await HelperBrokerClient.screen(at: fixture.socket).flatMap(WarmScreenFacts.init(encoded:)) }
    }
}

@Suite("Android display facts from the warm helper")
@MainActor
struct AndroidWarmScreenTests {
    static let pixel9Screen = UIScreenInfo(
        width: 411.43, height: 923.43, scale: 2.625, rotation: .portrait, rotationDegrees: 0,
        display: ScreenDisplay(id: "main", platformId: FoldableFixtures.pixel9Id)
    )

    @Test("an emulator with one panel reads its displays from the shell once, then from the warm helper, with the same screen")
    func onePanelReadsShellOnce() async throws {
        let rig = try await WarmScreenRig(status: WarmScreenRig.pixel9Status, probe: FoldableFixtures.pixel9Geometry)

        let first = try await rig.describe()
        let second = try await rig.describe()
        let third = try await rig.describe()

        #expect(rig.statusReads == 1)
        #expect(first == Self.pixel9Screen)
        #expect(second == first && third == first)
        #expect(await rig.keptFacts?.status == WarmScreenRig.pixel9Status)
        #expect(!rig.fixture.device.ops.contains("screen") && !rig.fixture.device.ops.contains("rememberScreen"), "\(rig.fixture.device.ops)")
        try await rig.fixture.stop()
    }

    @Test("a foldable reads its displays from the shell every command, so its posture stays live")
    func foldableReadsShellEachCommand() async throws {
        let status = FoldableFixtures.status(FoldableFixtures.foldPrintStates, FoldableFixtures.foldStateClosed, FoldableFixtures.foldDumpsysClosed)
        let rig = try await WarmScreenRig(status: status, probe: FoldableFixtures.foldGeometryClosed)

        let first = try await rig.describe()
        let second = try await rig.describe()

        #expect(rig.statusReads == 2)
        #expect(first?.posture == .closed)
        #expect(first?.display == ScreenDisplay(id: "cover", platformId: FoldableFixtures.coverId))
        #expect(second == first)
        #expect(await rig.keptFacts == nil)
        try await rig.fixture.stop()
    }

    @Test("kept facts naming a panel the screen no longer fits are read again from the shell, and replaced")
    func staleFactsAreReadAgain() async throws {
        let rig = try await WarmScreenRig(status: WarmScreenRig.pixel9Status, probe: FoldableFixtures.pixel9Geometry)
        let stale = WarmScreenFacts(
            status: WarmScreenRig.pixel9Status.replacingOccurrences(of: "1080 x 2424", with: "1440 x 3120"),
            viewport: "local:\(FoldableFixtures.pixel9Id)", apiLevel: 36
        )
        _ = try await rig.describe()
        #expect(await HelperBrokerClient.rememberScreen(try #require(stale.encoded), at: rig.fixture.socket))

        let screen = try await rig.describe()

        #expect(rig.statusReads == 2)
        #expect(screen == Self.pixel9Screen)
        #expect(await rig.keptFacts?.status == WarmScreenRig.pixel9Status)
        try await rig.fixture.stop()
    }

    @Test("kept facts another build's script printed are ignored")
    func otherScriptIgnored() throws {
        let facts = WarmScreenFacts(status: WarmScreenRig.pixel9Status, viewport: nil, apiLevel: nil)
        let encoded = try #require(facts.encoded)
        #expect(WarmScreenFacts(encoded: encoded) == facts)
        #expect(WarmScreenFacts(encoded: encoded.replacingOccurrences(of: "print-states", with: "print-state")) == nil)
    }
}
