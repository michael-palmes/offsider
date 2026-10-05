import Foundation
import OffsiderCore
import XPC

/// A device's UniversalHID service over one CoreDevice feature socket: lists its HID surfaces and sends them raw reports.
@MainActor
public final class UniversalHIDService {
    public enum Outcome: Equatable, Sendable {
        case reply(UniversalHIDValue)
        case refused(CoreDeviceErrorInfo)
        case connectionLost(String)
        case timedOut
    }

    static let replyTimeoutSeconds: Double = 3
    /// The device drops touchscreen reports for about 80 ms after the socket opens, so a tap sent at once never lands.
    public static let activationFloor: Duration = .milliseconds(250)

    private let socket: CoreDeviceServiceSocket
    private let name: String
    private let udid: String
    public private(set) var hasSent = false

    private init(socket: CoreDeviceServiceSocket, name: String, udid: String) {
        self.socket = socket
        self.name = name
        self.udid = udid
    }

    public static func connect(deviceIdentifier: String, version: CoreDeviceVersion, name: String, udid: String) async throws -> UniversalHIDService {
        let feature = UniversalHIDMessage.feature
        let socket: CoreDeviceServiceSocket
        do {
            socket = try await CoreDeviceServiceSocket.open(deviceIdentifier: deviceIdentifier, feature: feature, version: version)
        } catch let failure as CoreDeviceServiceSocket.Failure {
            switch failure {
            case .refused(let error):
                throw IOSDeviceError.serviceSocket(error, feature: feature, name: name, udid: udid, sent: false)
            case .symbolsUnavailable:
                throw IOSDeviceError.hidFailed(name, udid: udid, detail: "this macOS has no RemoteXPC client", sent: false)
            case .noDescriptor, .connectionFailed:
                throw IOSDeviceError.hidFailed(name, udid: udid, detail: "CoreDevice opened \(feature) without a usable socket", sent: false)
            }
        }
        do {
            try await Task.sleep(for: activationFloor)
        } catch {
            socket.cancel()
            throw error
        }
        return UniversalHIDService(socket: socket, name: name, udid: udid)
    }

    /// The device's registered surfaces; also proves the service is live and willing.
    public func connectedServices() async throws -> [UniversalHIDSurface] {
        let reply = try await answer(UniversalHIDMessage.connectedServices(), doing: "list its HID surfaces")
        return UniversalHIDSurface.parse(reply)
    }

    /// Registers a host keyboard surface and returns the service ID the device chose.
    public func createKeyboardService(id serviceID: UInt64 = UniversalHIDMessage.virtualKeyboardServiceID) async throws -> UInt64 {
        let reply = try await answer(UniversalHIDMessage.createKeyboardService(id: serviceID), doing: "create a keyboard surface")
        return reply["serviceID"]?.unsigned ?? reply["_ServiceID"]?.unsigned ?? serviceID
    }

    /// Fire and forget, so a contact's hold is the caller's to time; `confirm()` waits until the device has read everything sent before it.
    public func send(_ report: Data, to serviceID: UInt64) {
        hasSent = true
        socket.send(UniversalHIDMessage.send(report, to: serviceID).xpcObject)
    }

    /// A request on the same connection is answered only after every report before it was read.
    public func confirm() async throws {
        _ = try await answer(UniversalHIDMessage.connectedServices(), doing: "confirm the input")
    }

    public func close() {
        socket.cancel()
    }

    func answer(_ message: UniversalHIDValue, doing what: String) async throws -> UniversalHIDValue {
        switch await request(message) {
        case .reply(let value):
            return value
        case .refused(let error):
            throw error.isLocked
                ? IOSDeviceError.locked(name, udid: udid, sent: hasSent)
                : IOSDeviceError.hidFailed(name, udid: udid, detail: "the device refused to \(what): \(error.summary)", sent: hasSent)
        case .connectionLost(let detail):
            throw IOSDeviceError.hidFailed(name, udid: udid, detail: "\(UniversalHIDMessage.feature) closed while trying to \(what): \(detail)", sent: hasSent)
        case .timedOut:
            throw IOSDeviceError.hidFailed(name, udid: udid, detail: "\(UniversalHIDMessage.feature) did not answer within \(Int(Self.replyTimeoutSeconds)) s", sent: hasSent)
        }
    }

    func request(_ message: UniversalHIDValue) async -> Outcome {
        let object = message.xpcObject
        let socket = socket
        return await replyOrTimeout(within: Self.replyTimeoutSeconds, timedOut: .timedOut) { answer in
            socket.send(object) { answer(Self.outcome($0)) }
        }
    }

    nonisolated static func outcome(_ reply: xpc_object_t) -> Outcome {
        switch DTUHIDReply(xpc: reply) {
        case .refused(let error): return .refused(error)
        case .connectionLost(let detail): return .connectionLost(detail)
        case .timedOut: return .timedOut
        case .answered: return .reply(UniversalHIDValue(xpc: reply))
        }
    }
}
