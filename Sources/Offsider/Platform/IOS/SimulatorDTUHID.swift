import Darwin
import FBSimulatorControl
import Foundation
import OffsiderCore
import XPC

/// A connection to one of the simulator's `dtuhidd` services, built as idb's DTUHID transport builds its digitizer connection.
/// idb only sends to the main screen's digitizer, so Offsider reaches other touchscreens and the hinge through this.
final class SimulatorDTUHID: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case symbolsUnavailable
        case serviceUnavailable(String, NSError?)
        case connectionFailed(String)
        case unresponsive(String)

        var description: String {
            switch self {
            case .symbolsUnavailable: return "the XPC simulator symbols are unavailable"
            case let .serviceUnavailable(service, error): return "\(service) is unavailable: \(error?.localizedDescription ?? "no port")"
            case let .connectionFailed(service): return "could not connect to \(service)"
            case let .unresponsive(service): return "\(service) did not answer"
            }
        }
    }

    static let replyTimeoutSeconds: Double = 2
    static let replyTail: Duration = .milliseconds(200)

    let service: String
    private let connection: xpc_connection_t
    private var hasSent = false

    private init(service: String, connection: xpc_connection_t) {
        self.service = service
        self.connection = connection
    }

    /// Connects and proves a live `dtuhidd` with a barrier round trip, then waits out the activation floor.
    static func connect(to simulator: FBSimulator, service: String, attempts: Int = 3) async throws -> SimulatorDTUHID {
        var lastFailure: Error = Failure.unresponsive(service)
        for attempt in 1...attempts {
            let started = ContinuousClock.now
            let link = SimulatorDTUHID(service: service, connection: try makeConnection(simulator: simulator, service: service))
            if await link.roundTrip(DTUHIDMessage.barrier(service: service)) {
                let remaining = DTUHIDMessage.activationFloor - (ContinuousClock.now - started)
                if remaining > .zero { try await Task.sleep(for: remaining) }
                return link
            }
            link.cancel()
            lastFailure = Failure.unresponsive(service)
            if attempt < attempts { try await Task.sleep(for: .seconds(1)) }
        }
        throw lastFailure
    }

    /// Writes one message; returns once XPC has sent it.
    func send(_ message: DTUHIDValue) async {
        hasSent = true
        let object = message.xpcObject
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            xpc_connection_send_message(connection, object)
            xpc_connection_send_barrier(connection) { continuation.resume() }
        }
    }

    /// Lets what was sent reach the guest before disconnecting: a barrier reply, then a short tail.
    func close() async {
        if hasSent, await roundTrip(DTUHIDMessage.barrier(service: service)) {
            try? await Task.sleep(for: Self.replyTail)
        }
        cancel()
    }

    func cancel() {
        xpc_connection_cancel(connection)
    }

    /// True when `dtuhidd` itself answered before the timeout.
    private func roundTrip(_ message: DTUHIDValue) async -> Bool {
        let object = message.xpcObject
        let connection = connection
        let queue = DispatchQueue.global(qos: .userInitiated)
        return await replyOrTimeout(within: Self.replyTimeoutSeconds, timedOut: false, on: queue) { answer in
            xpc_connection_send_message_with_reply(connection, object, queue) { answer(xpc_get_type($0) != XPC_TYPE_ERROR) }
        }
    }

    private typealias EndpointFromMachPort = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    private typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> xpc_connection_t?
    private typealias EnableSimToHost = @convention(c) (xpc_connection_t) -> Void
    private typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> mach_port_t

    /// `SimDevice` is private CoreSimulator, so its `lookup:error:` is called through the runtime.
    private static func makeConnection(simulator: FBSimulator, service: String) throws -> xpc_connection_t {
        guard let handle = dlopen(nil, RTLD_NOW),
              let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let connectionSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
              let simToHostSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
            throw Failure.symbolsUnavailable
        }
        let selector = NSSelectorFromString("lookup:error:")
        guard simulator.responds(to: NSSelectorFromString("device")),
              let device = simulator.value(forKey: "device") as? NSObject,
              device.responds(to: selector),
              let method = device.method(for: selector) else {
            throw Failure.serviceUnavailable(service, nil)
        }
        var error: NSError?
        let port = unsafeBitCast(method, to: Lookup.self)(device, selector, service as NSString, &error)
        guard port != 0 else { throw Failure.serviceUnavailable(service, error) }
        guard let endpoint = unsafeBitCast(endpointSymbol, to: EndpointFromMachPort.self)(port, 0, 0),
              let connection = unsafeBitCast(connectionSymbol, to: ConnectionFromEndpoint.self)(endpoint) else {
            throw Failure.connectionFailed(service)
        }
        // Without this the daemon sees the peer but never the payload.
        unsafeBitCast(simToHostSymbol, to: EnableSimToHost.self)(connection)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        return connection
    }
}
