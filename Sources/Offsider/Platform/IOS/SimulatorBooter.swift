import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import OffsiderCore

/// Boots an iOS simulator through FBSimulatorControl, as `xcrun simctl boot` would, and waits until it is usable.
@MainActor
struct SimulatorBooter {
    let logger: OffsiderLogger

    /// The iOS simulator `target` names, or nil when none does; several with one name is a usage error.
    func find(_ target: String, command: String = "boot") async throws -> FBSimulator? {
        try await IOSBackend(logger: logger).prepare()
        let simulators = try await getSimulatorSet(logger: logger).allSimulators
        let candidates = simulators.map {
            SimulatorBootCandidate(udid: $0.udid, name: $0.name, state: FBiOSTargetStateStringFromState($0.state).rawValue, osVersion: $0.osVersion.name.rawValue)
        }
        switch SimulatorBootTarget.match(target, among: candidates) {
        case .none: return nil
        case .one(let candidate): return simulators.first { $0.udid == candidate.udid }
        case .several(let several):
            throw CLIError(errorDescription: SimulatorBootTarget.ambiguity(target, several, command: command), reason: .deviceAmbiguous, hint: "offsider \(command) \(several[0].udid)")
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

extension SimulatorBooter {
    /// Returns whether it was already off; a stop that outlasts `timeout` names the fix, and the simulator must read as off for this to return.
    func shutdown(_ simulator: FBSimulator, timeout: Duration) async throws -> Bool {
        let step = SimulatorShutdownStep.step(for: FBiOSTargetStateStringFromState(simulator.state).rawValue)
        if step == .alreadyOff { return true }
        let target = SimulatorBox(simulator)
        let name = "\(simulator.name) (\(simulator.udid))"
        let finished: Bool
        do {
            if step == .waitForShutdown {
                finished = try await DetachedWait.finishes(within: timeout) { try await target.simulator.resolveState(.shutdown) }
            } else {
                let future = FutureBox(FBSimulatorShutdownStrategy.shutdown(simulator))
                finished = try await DetachedWait.finishes(within: timeout) { _ = try await bridgeFBFuture(future.future) }
            }
        } catch {
            throw CLIError(errorDescription: "\(name) did not stop (\(error.localizedDescription)). Try `xcrun simctl shutdown \(simulator.udid)`.", reason: .shutdownFailed, hint: "xcrun simctl shutdown \(simulator.udid)")
        }
        guard finished, SimulatorShutdownStep.step(for: FBiOSTargetStateStringFromState(simulator.state).rawValue) == .alreadyOff else {
            throw CLIError(
                errorDescription: "\(name) was still running after \(timeout.components.seconds) s. Run this again with a longer --timeout, or try `xcrun simctl shutdown \(simulator.udid)`.",
                reason: .shutdownTimedOut, hint: "xcrun simctl shutdown \(simulator.udid)"
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
