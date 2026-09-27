import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import OffsiderCore

/// Adapter over the existing simulator utilities; each call forwards with the arguments the commands used.
@MainActor
final class IOSBackend: DeviceBackend {
    let logger: OffsiderLogger
    private var simulators: [String: FBSimulator] = [:]

    init(logger: OffsiderLogger) {
        self.logger = logger
    }

    var platform: DevicePlatform { .ios }

    func prepare() async throws {
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
    }

    func listDevices() async throws -> [DeviceSummary] {
        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        return simulatorSet.allSimulators.map { simulator in
            DeviceSummary(
                id: simulator.udid,
                platform: .ios,
                state: FBiOSTargetStateStringFromState(simulator.state).rawValue,
                name: simulator.name,
                osVersion: simulator.osVersion.name.rawValue,
                deviceType: simulator.deviceType.model.rawValue
            )
        }
    }

    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice {
        let udid = id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw CLIError(errorDescription: "Device ID cannot be empty. Use --device to choose a device.")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == udid }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(udid) not found.")
        }

        guard simulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(simulator.state)
            throw CLIError(errorDescription: "Simulator \(udid) is not booted. Current state: \(stateDescription)")
        }

        simulators[udid] = simulator
        return BootedDevice(id: DeviceID(rawValue: udid, platform: .ios), name: simulator.name)
    }

    func accessibilityJSON(for id: DeviceID, point: AccessibilityPoint?) async throws -> Data {
        try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(for: id.rawValue, point: point, logger: logger)
    }

    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        roots: [AccessibilityElement]?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)] {
        if let roots {
            return try await OrientationAwareCoordinates.translateBatch(
                points: points,
                roots: roots,
                for: id.rawValue,
                logger: logger
            )
        }
        return try await OrientationAwareCoordinates.translateBatch(points: points, for: id.rawValue, logger: logger)
    }

    func openInputSession(for id: DeviceID) async throws -> any InputSession {
        let hidSession = try await HIDInteractor.makeSession(for: id.rawValue, logger: logger)
        simulators[id.rawValue] = hidSession.simulator
        return IOSInputSession(hidSession: hidSession, logger: logger)
    }

    /// Nonisolated so the blocking broker exchange stays off the main actor, as when `touch` called it directly.
    nonisolated func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        try HIDBroker.sendTouchPrimitives(steps.map(\.brokerPrimitive), simulatorUDID: id.rawValue)
    }

    func screenshotPNG(for id: DeviceID) async throws -> Data {
        try await VideoFrameUtilities.captureScreenshotData(from: try await simulator(for: id))
    }

    private func simulator(for id: DeviceID) async throws -> FBSimulator {
        if let simulator = simulators[id.rawValue] {
            return simulator
        }
        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == id.rawValue }) else {
            throw CLIError.deviceNotFound(id: id.rawValue)
        }
        simulators[id.rawValue] = simulator
        return simulator
    }
}

extension IOSBackend: RawVideoStreaming {
    func streamBGRA(
        from id: DeviceID,
        fps: Int,
        quality: Int,
        scale: Double,
        to fileDescriptor: Int32,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws {
        let simulator = try await self.simulator(for: id)

        let config = FBVideoStreamConfiguration(
            format: .bgra(),
            framesPerSecond: NSNumber(value: fps),
            rateControl: .quality(NSNumber(value: Double(quality) / 100.0)),
            scaleFactor: NSNumber(value: scale),
            keyFrameRate: nil
        )

        let stdoutConsumer = FBFileWriter.syncWriter(withFileDescriptor: fileDescriptor, closeOnEndOfFile: false)
        var videoStream: (any FBVideoStream)?
        var isStreaming = false

        do {
            let stream = try await simulator.createStream(configuration: config)
            videoStream = stream
            try await stream.startStreamingAsync(stdoutConsumer)
            isStreaming = true
            try await Task.sleep(nanoseconds: 1_000_000_000)
            FileHandle.standardError.write(Data("BGRA stream is now running...\n".utf8))

            while true {
                if Task.isCancelled {
                    break
                }
                if await isCancelled() {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            FileHandle.standardError.write(Data("\nStopping BGRA stream...\n".utf8))
            isStreaming = false
            try await stream.stopStreamingAsync()
            FileHandle.standardError.write(Data("BGRA stream stopped\n".utf8))
        } catch {
            if isStreaming, let videoStream {
                isStreaming = false
                try? await videoStream.stopStreamingAsync()
            }
            throw CLIError(errorDescription: "Failed to stream BGRA video: \(error.localizedDescription)")
        }
    }
}

extension DetachedTouchStep {
    var brokerPrimitive: HIDBrokerPrimitive {
        switch self {
        case let .down(x, y):
            return .touch(.down, x: x, y: y)
        case let .up(x, y):
            return .touch(.up, x: x, y: y)
        case let .hold(duration):
            return .delay(duration)
        }
    }
}
