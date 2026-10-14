import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import OffsiderCore

/// Boots an iOS simulator through FBSimulatorControl, as `xcrun simctl boot` would, and waits until it is usable.
@MainActor
struct SimulatorBooter {
    let logger: OffsiderLogger

    /// The iOS simulator `target` names, or nil when none does; several with one name is a usage error.
    func find(_ target: String) async throws -> FBSimulator? {
        try await IOSBackend(logger: logger).prepare()
        let simulators = try await getSimulatorSet(logger: logger).allSimulators
        let candidates = simulators.map {
            SimulatorBootCandidate(udid: $0.udid, name: $0.name, state: FBiOSTargetStateStringFromState($0.state).rawValue, osVersion: $0.osVersion.name.rawValue)
        }
        switch SimulatorBootTarget.match(target, among: candidates) {
        case .none: return nil
        case .one(let candidate): return simulators.first { $0.udid == candidate.udid }
        case .several(let several):
            throw CLIError(errorDescription: SimulatorBootTarget.ambiguity(target, several), reason: .deviceAmbiguous, hint: "offsider boot \(several[0].udid)")
        }
    }

    /// Returns whether it was already booted; a boot that outlasts `timeout` is an error, and the simulator keeps booting.
    func boot(_ simulator: FBSimulator, timeout: Duration, progress: (String) -> Void) async throws -> Bool {
        if simulator.state == .booted { return true }
        progress("Booting \(simulator.name) (\(simulator.udid)).")
        let future = FutureBox(simulator.boot(FBSimulatorBootConfiguration.default))
        let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { _ = try await bridgeFBFuture(future.future); return true }
            group.addTask { try await Task.sleep(for: timeout); return false }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        guard finished else {
            throw CLIError(
                errorDescription: "\(simulator.name) (\(simulator.udid)) did not finish booting within \(timeout.components.seconds) s. It may still be booting; run `offsider boot \(simulator.udid)` again to keep waiting.",
                reason: .bootTimedOut
            )
        }
        return false
    }
}
