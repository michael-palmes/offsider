import Foundation
import OffsiderCore
import XPC

/// A device `dtuhidd` service over one CoreDevice feature socket, mirroring `SimulatorDTUHID`'s barrier round trip.
@MainActor
final class DeviceDTUHID {
    static let replyTimeoutSeconds: Double = 2
    static let replyTail: Duration = .milliseconds(200)

    let feature: String
    private let socket: CoreDeviceServiceSocket
    private(set) var hasSent = false
    let firstMessageAt: ContinuousClock.Instant

    private init(feature: String, socket: CoreDeviceServiceSocket) {
        self.feature = feature
        self.socket = socket
        firstMessageAt = .now
    }

    /// Opens the feature socket and proves a live, willing `dtuhidd` with a barrier before any event is sent.
    static func connect(
        deviceIdentifier: String, feature: String, version: CoreDeviceVersion, name: String, udid: String, anySent: Bool
    ) async throws -> DeviceDTUHID {
        let socket: CoreDeviceServiceSocket
        do {
            socket = try await CoreDeviceServiceSocket.open(deviceIdentifier: deviceIdentifier, feature: feature, version: version)
        } catch let failure as CoreDeviceServiceSocket.Failure {
            switch failure {
            case .refused(let error):
                throw IOSDeviceError.serviceSocket(error, feature: feature, name: name, udid: udid, sent: anySent)
            case .symbolsUnavailable:
                throw IOSDeviceError.hidFailed(name, udid: udid, detail: "this macOS has no RemoteXPC client", sent: anySent)
            case .noDescriptor, .connectionFailed:
                throw IOSDeviceError.hidFailed(name, udid: udid, detail: "CoreDevice opened \(feature) without a usable socket", sent: anySent)
            }
        }
        let link = DeviceDTUHID(feature: feature, socket: socket)
        switch await link.roundTrip(DTUHIDMessage.barrier(service: feature)) {
        case .answered:
            return link
        case .refused(let error):
            socket.cancel()
            throw IOSDeviceError.barrierRefused(error, name: name, udid: udid, sent: anySent)
        case .connectionLost(let detail):
            socket.cancel()
            throw IOSDeviceError.hidFailed(name, udid: udid, detail: "\(feature) closed: \(detail)", sent: anySent)
        case .timedOut:
            socket.cancel()
            throw IOSDeviceError.hidFailed(name, udid: udid, detail: "\(feature) did not answer within \(Int(replyTimeoutSeconds)) s", sent: anySent)
        }
    }

    func send(_ message: DTUHIDValue) {
        hasSent = true
        socket.send(DTUHIDMessage.forDevice(message).xpcObject)
    }

    /// A harmless keyboard usage 0 that is not a barrier, which a device refuses when UI Automation is off.
    func probe() async -> DTUHIDReply {
        await roundTrip(DTUHIDMessage.envelope("IndigoKeyboardButtonEvent", service: feature, payload: ["usageCode": .uint(0), "state": .uint(DTUHIDMessage.ButtonState.up.rawValue)]))
    }

    /// Lets what was sent reach the device before disconnecting: a barrier reply, then a short tail.
    func close() async {
        if hasSent, await roundTrip(DTUHIDMessage.barrier(service: feature)) == .answered {
            try? await Task.sleep(for: Self.replyTail)
        }
        socket.cancel()
    }

    func roundTrip(_ message: DTUHIDValue) async -> DTUHIDReply {
        let object = DTUHIDMessage.forDevice(message).xpcObject
        let socket = socket
        let once = OnceFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<DTUHIDReply, Never>) in
            socket.send(object) { reply in
                let answer = DTUHIDReply(xpc: reply)
                if once.claim() { continuation.resume(returning: answer) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.replyTimeoutSeconds) {
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }
}

extension DeviceDTUHID: DeviceHIDLink {}

/// True for exactly one caller, which resumes the continuation.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasPending = pending
        pending = false
        return wasPending
    }
}
