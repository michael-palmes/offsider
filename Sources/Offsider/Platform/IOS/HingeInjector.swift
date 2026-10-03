import FBSimulatorControl
import Foundation
import OffsiderCore

/// Moves a foldable simulator's hinge as Device Hub's slider does: a sweep of angles to `dtuhidd`'s vendor-defined service.
enum HingeInjector {
    /// Throws `SimulatorDTUHID.Failure` when the runtime has no hinge service.
    static func sweep(_ simulator: FBSimulator, from start: Int, to end: Int, logger: OffsiderLogger) async throws {
        let link = try await SimulatorDTUHID.connect(to: simulator, service: DTUHIDMessage.vendorDefinedService)
        let angles = HingeControl.sweep(from: start, to: end)
        logger.info().log("Hinge sweep \(start) to \(end) in \(angles.count) events")
        let clock = ContinuousClock()
        var next = clock.now
        for angle in angles {
            await link.send(HingeControl.event(degrees: angle))
            next = next.advanced(by: .seconds(HingeControl.sweepInterval))
            try? await clock.sleep(until: next)
        }
        await link.close()
    }
}
