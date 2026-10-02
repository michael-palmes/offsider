import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android system bars")
@MainActor
struct SystemBarsTests {
    static let device = HelperRig.device
    static let statusBar = FakeHelperDevice.statusBar
    static let gestureBar = #"{"id":2299,"type":"system","layer":2,"bounds":[0,2361,1080,2424],"active":false,"focused":false}"#
    static let shade = #"{"id":2300,"type":"system","layer":3,"bounds":[0,0,1080,2424],"active":false,"focused":false}"#

    nonisolated static func dump(windows: [String]) -> String {
        FakeHelperDevice.tapTestDump.replacingOccurrences(of: "[\(FakeHelperDevice.statusBar),", with: "[" + windows.map { $0 + "," }.joined())
    }

    /// The E2E AVD's display: 1080 x 2424 pixels at 420 dpi.
    static func display() throws -> HelperDisplay {
        try JSONDecoder().decode(HelperDisplayReply.self, from: Data(FakeHelperDevice.displayReply.utf8)).display
    }

    static func windows(_ json: [String]) throws -> [HelperWindow] {
        try JSONDecoder().decode([HelperWindow].self, from: Data("[\(json.joined(separator: ","))]".utf8))
    }

    @Test("the status bar and a gesture bar on a Pixel 9 (2.625 px per dp) give 54.1 dp and 24 dp")
    func statusAndGestureBars() throws {
        let bands = SystemBars.bands(windows: try Self.windows([Self.statusBar, Self.gestureBar]), display: try Self.display())
        #expect(bands == ScreenBands(top: 54.1, bottom: 24))
    }

    @Test("no bar windows give no bands, as gesture navigation without a handle window does")
    func noBars() throws {
        #expect(SystemBars.bands(windows: [], display: try Self.display()) == ScreenBands(top: 0, bottom: 0))
        #expect(SystemBars.bands(windows: try Self.windows([Self.statusBar]), display: try Self.display()) == ScreenBands(top: 54.1, bottom: 0))
    }

    @Test("a tall system window such as the notification shade is not a bar")
    func shadeIgnored() throws {
        let bands = SystemBars.bands(windows: try Self.windows([Self.shade, Self.statusBar]), display: try Self.display())
        #expect(bands == ScreenBands(top: 54.1, bottom: 0))
    }

    @Test("with no helper running, the backend keeps the 60 and 48 dp bands")
    func noHelperFallback() async throws {
        let rig = try HelperRig()
        #expect(await rig.backend.volatileScreenBands(for: Self.device) == ScreenBands(top: 60, bottom: 48))
        #expect(rig.server.connectionAttempts == 0)
    }

    @Test("after a helper read, the backend's bands come from that dump's windows")
    func fromLatestDump() async throws {
        let device = FakeHelperDevice()
        device.dump = Self.dump(windows: [Self.statusBar, Self.gestureBar])
        let rig = try HelperRig(device)
        _ = try await rig.read()

        #expect(await rig.backend.volatileScreenBands(for: Self.device) == ScreenBands(top: 54.1, bottom: 24))
        #expect(rig.device.ops == ["hello", "dump"])
        await rig.backend.close()
    }
}
