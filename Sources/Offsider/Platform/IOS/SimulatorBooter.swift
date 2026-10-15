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

    /// Returns whether it was already booted. A boot that outlasts `timeout` is an error, yet it carries on, so running `boot` again
    /// finds the simulator booting and waits for it rather than starting another.
    func boot(_ simulator: FBSimulator, timeout: Duration, progress: (String) -> Void) async throws -> Bool {
        let step = SimulatorBootStep.step(for: FBiOSTargetStateStringFromState(simulator.state).rawValue)
        if step == .alreadyBooted { return true }
        let target = SimulatorBox(simulator)
        let finished: Bool
        if step == .waitForBoot {
            progress("Waiting for \(simulator.name) (\(simulator.udid)), which is already booting.")
            finished = try await DetachedWait.finishes(within: timeout) { try await target.simulator.resolveState(.booted) }
        } else {
            progress("Booting \(simulator.name) (\(simulator.udid)).")
            let future = FutureBox(simulator.boot(FBSimulatorBootConfiguration.default))
            finished = try await DetachedWait.finishes(within: timeout) { _ = try await bridgeFBFuture(future.future) }
        }
        guard finished else {
            throw CLIError(
                errorDescription: "\(simulator.name) (\(simulator.udid)) did not finish booting within \(timeout.components.seconds) s. It carries on booting; run `offsider boot \(simulator.udid)` again to keep waiting.",
                reason: .bootTimedOut
            )
        }
        return false
    }
}

/// Lets a boot wait run off the main actor; FBSimulator does its own locking.
private final class SimulatorBox: @unchecked Sendable {
    let simulator: FBSimulator
    init(_ simulator: FBSimulator) { self.simulator = simulator }
}
