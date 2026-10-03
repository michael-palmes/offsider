import Foundation
import FBControlCore
import FBSimulatorControl

/// One value per device-set path for the life of the process, rebuilt on demand when a lookup misses.
@MainActor
final class DeviceSetCache<DeviceSet> {
    private var sets: [String: DeviceSet] = [:]

    func set(deviceSetPath: String?, build: () throws -> DeviceSet) rethrows -> DeviceSet {
        let key = deviceSetPath ?? ""
        if let cached = sets[key] {
            return cached
        }
        let built = try build()
        sets[key] = built
        return built
    }

    /// Rebuilds once on a miss so a device created or booted after the first build is still found.
    func lookup<Value>(
        deviceSetPath: String?,
        build: () throws -> DeviceSet,
        find: (DeviceSet) -> Value?
    ) rethrows -> Value? {
        if let value = find(try set(deviceSetPath: deviceSetPath, build: build)) {
            return value
        }
        let rebuilt = try build()
        sets[deviceSetPath ?? ""] = rebuilt
        return find(rebuilt)
    }
}

@MainActor
private let simulatorSets = DeviceSetCache<FBSimulatorSet>()

@MainActor
private func makeSimulatorSet(deviceSetPath: String?, logger: OffsiderLogger, reporter: FBEventReporter) throws -> FBSimulatorSet {
    try Timings.measure("simulator-set") {
        FBControlCoreGlobalConfiguration.defaultLogger = logger
        let configuration = FBSimulatorControlConfiguration(
            deviceSetPath: deviceSetPath,
            logger: logger,
            reporter: reporter
        )
        do {
            return try FBSimulatorControl.withConfiguration(configuration).set
        } catch {
            logger.info().log("FBSimulatorControl failed to initialize.")
            throw error
        }
    }
}

/// The process-wide simulator set; `FBSimulator.state` reads CoreSimulator live, so cached entries stay current.
@MainActor
func getSimulatorSet(
    deviceSetPath: String? = nil,
    logger: OffsiderLogger,
    reporter: FBEventReporter = EmptyEventReporter.shared
) async throws -> FBSimulatorSet {
    try simulatorSets.set(deviceSetPath: deviceSetPath) {
        try makeSimulatorSet(deviceSetPath: deviceSetPath, logger: logger, reporter: reporter)
    }
}

@MainActor
func cachedSimulator(
    udid: String,
    deviceSetPath: String? = nil,
    logger: OffsiderLogger
) async throws -> FBSimulator? {
    try simulatorSets.lookup(
        deviceSetPath: deviceSetPath,
        build: { try makeSimulatorSet(deviceSetPath: deviceSetPath, logger: logger, reporter: EmptyEventReporter.shared) },
        find: { set in set.allSimulators.first { $0.udid == udid } }
    )
}
