import FBSimulatorControl
import Foundation
import OffsiderCore

/// Input through the simulator's warm broker on one connection per command; if the broker goes before a request reaches it, the command opens its own session.
@MainActor
final class SimulatorInputSession: InputSession {
    let device: DeviceID
    private let connection: HIDBrokerConnection
    private let logger: OffsiderLogger
    private var direct: HIDInteractor.Session?

    init(device: DeviceID, connection: HIDBrokerConnection, logger: OffsiderLogger) {
        self.device = device
        self.connection = connection
        self.logger = logger
    }

    func perform(_ event: InputEvent) async throws {
        let hidEvent = try event.hidEvent()
        if let direct {
            try await HIDInteractor.performHIDEvent(hidEvent, in: direct, logger: logger)
            return
        }
        do {
            try await Timings.measure("hid-send") { try await connection.send(hidEvent) }
        } catch let notSent as HIDBrokerNotSent {
            logger.info().log("The simulator input broker went before this input reached it (\(notSent.detail)); opening a session of this command's own")
            connection.close()
            let session = try await Timings.measure("hid-session") {
                try await HIDInteractor.makeSession(for: device.rawValue, logger: logger)
            }
            direct = session
            try await HIDInteractor.performHIDEvent(hidEvent, in: session, logger: logger)
        }
    }

    func close() async {
        connection.close()
        if let direct { await HIDInteractor.closeSession(direct) }
        direct = nil
    }
}

/// One command's connection to its simulator's broker; blocking socket I/O runs on a queue of its own, off the main actor.
final class HIDBrokerConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "offsider.hid-broker.client")
    private var isClosed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if !isClosed { Darwin.close(descriptor) }
    }

    /// Off the main actor, as the handshake read blocks.
    static func attach(simulatorUDID: String) async -> HIDBroker.Attachment {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: HIDBroker.attach(simulatorUDID: simulatorUDID))
            }
        }
    }

    func send(_ event: FBSimulatorHIDEvent, environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        let request = try HIDBroker.request(for: event, keepHeld: false, environment: environment)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result {
                    guard !self.isClosed else { throw HIDBrokerNotSent(detail: "the connection is closed") }
                    _ = try HIDBroker.exchange(request.data, on: self.descriptor, timeoutMilliseconds: request.timeoutMilliseconds)
                })
            }
        }
    }

    func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(descriptor)
        }
    }
}
