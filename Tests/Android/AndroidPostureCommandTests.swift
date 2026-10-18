import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

@Suite("Android posture command")
@MainActor
struct AndroidPostureCommandTests {
    @Test("posture closed reports the cover once the panel swaps, though the first read after the state commits still shows the inner panel")
    func closedWaitsForPanelSwap() async throws {
        let rig = try AndroidFoldableBackendTests.rig(grpc: false)
        rig.fold.lagPanelSwap(2)
        let clock = ScriptedClock()

        let line = try await PostureCommand.report(
            .closed, json: false, timeout: 10, on: AndroidFoldableBackendTests.device, backend: rig.backend, deviceName: "emulator-5556",
            sleep: clock.poll.sleep, now: clock.poll.now
        )

        #expect(line == "Posture: closed (cover, 443.08 x 994.46 dp)")
        #expect(clock.now < 2)
    }

    @Test("posture closed whose first read after the state commits already shows the cover reports it without waiting or reading again")
    func closedPanelSwappedAtOnce() async throws {
        let rig = try AndroidFoldableBackendTests.rig(grpc: false)
        let clock = ScriptedClock()

        let line = try await PostureCommand.report(
            .closed, json: false, timeout: 10, on: AndroidFoldableBackendTests.device, backend: rig.backend, deviceName: "emulator-5556",
            sleep: clock.poll.sleep, now: clock.poll.now
        )

        #expect(line == "Posture: closed (cover, 443.08 x 994.46 dp)")
        #expect(clock.now == 0)
        #expect(rig.shellCommands.filter { $0.hasPrefix(AndroidDisplayStatus.script) }.count == 2, "\(rig.shellCommands)")
    }
}
