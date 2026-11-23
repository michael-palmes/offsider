import Darwin
import Foundation
import OffsiderCore
import XPC

/// One device feature's RemoteXPC connection, opened through CoreDeviceService's `createservicesocket` action as ipb does.
@safe final class CoreDeviceServiceSocket: @unchecked Sendable {
    enum Failure: Error {
        case symbolsUnavailable
        case refused(CoreDeviceErrorInfo)
        case noDescriptor
        case connectionFailed
    }

    static let serviceName = "com.apple.CoreDevice.CoreDeviceService"
    static let action = "com.apple.coredevice.action.createservicesocket"

    let feature: String
    private let connection: UnsafeMutableRawPointer
    private let queue: DispatchQueue
    private let symbols: RemoteXPC
    private let traffic: ConnectionTraffic

    private init(feature: String, connection: UnsafeMutableRawPointer, queue: DispatchQueue, symbols: RemoteXPC, traffic: ConnectionTraffic) {
        self.feature = feature
        unsafe self.connection = unsafe connection
        self.queue = queue
        unsafe self.symbols = unsafe symbols
        self.traffic = traffic
    }

    /// Messages handed to the connection so far.
    var sentCount: Int { traffic.sentCount }

    /// How many messages had been handed over when the connection's first error was noticed; nil while it has had none.
    var endedAfter: Int? { traffic.endedAfter }

    /// How many messages had been handed over when the connection was invalidated, after which it carries nothing; nil until then.
    var invalidatedAfter: Int? { traffic.invalidatedAfter }

    static let openTimeoutSeconds: Double = 10

    static func open(deviceIdentifier: String, feature: String, version: CoreDeviceVersion) async throws -> CoreDeviceServiceSocket {
        guard let symbols = unsafe RemoteXPC.shared else { throw Failure.symbolsUnavailable }
        let input = xpc_dictionary_create(nil, nil, 0)
        unsafe xpc_dictionary_set_string(input, "featureIdentifier", feature)
        let request = envelope(action: action, deviceIdentifier: deviceIdentifier, version: version, input: input)

        let service = unsafe symbols.serviceConnection()
        defer { xpc_connection_cancel(service) }
        guard let reply = await reply(to: request, on: service) else {
            throw Failure.refused(CoreDeviceErrorInfo(domain: serviceName, code: 0, description: "CoreDeviceService did not answer within \(Int(openTimeoutSeconds)) s"))
        }
        guard unsafe xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              let output = unsafe xpc_dictionary_get_value(reply, "CoreDevice.output"),
              unsafe xpc_get_type(output) == XPC_TYPE_DICTIONARY else {
            let error = unsafe xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(reply, "CoreDevice.error").flatMap(CoreDeviceErrorInfo.init(xpc:)) : nil
            let fallback = unsafe xpc_get_type(reply) == XPC_TYPE_ERROR
                ? (xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { unsafe String(cString: $0) } ?? "CoreDeviceService closed the connection")
                : "CoreDeviceService sent no socket"
            throw Failure.refused(error ?? CoreDeviceErrorInfo(domain: serviceName, code: 0, description: fallback))
        }
        let descriptor = unsafe xpc_dictionary_dup_fd(output, "fileDescriptor")
        guard descriptor >= 0 else { throw Failure.noDescriptor }
        let flags = unsafe xpc_dictionary_get_uint64(output, "remoteXPCVersionFlags")
        let queue = DispatchQueue(label: "offsider.coredevice.\(feature)", qos: .userInitiated)
        guard let connection = unsafe symbols.create(descriptor, Unmanaged.passUnretained(queue).toOpaque(), flags, 0) else {
            close(descriptor)
            throw Failure.connectionFailed
        }
        let traffic = ConnectionTraffic()
        // The only events a feature socket sends unasked are XPC errors; only an invalidation is known to carry nothing after it.
        unsafe symbols.setEventHandler(connection) { event in
            if unsafe xpc_get_type(event) == XPC_TYPE_ERROR { traffic.noteError(invalidated: xpc_equal(event, XPC_ERROR_CONNECTION_INVALID)) }
        }
        unsafe symbols.activate(connection)
        return unsafe CoreDeviceServiceSocket(feature: feature, connection: connection, queue: queue, symbols: symbols, traffic: traffic)
    }

    /// The `CoreDevice.*` action envelope that CoreDeviceService and the device's feature services both decode.
    static func envelope(action: String, deviceIdentifier: String, version: CoreDeviceVersion, input: xpc_object_t) -> xpc_object_t {
        let request = xpc_dictionary_create(nil, nil, 0)
        unsafe xpc_dictionary_set_string(request, "CoreDevice.actionIdentifier", action)
        unsafe xpc_dictionary_set_string(request, "CoreDevice.deviceIdentifier", deviceIdentifier)
        unsafe xpc_dictionary_set_value(request, "CoreDevice.coreDeviceVersion", version.xpcObject)
        unsafe xpc_dictionary_set_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion", 1)
        unsafe xpc_dictionary_set_string(request, "CoreDevice.invocationIdentifier", UUID().uuidString)
        unsafe xpc_dictionary_set_value(request, "CoreDevice.input", input)
        return request
    }

    /// Nil when nothing came back before the timeout.
    private static func reply(to request: xpc_object_t, on service: xpc_connection_t) async -> xpc_object_t? {
        let queue = DispatchQueue(label: "offsider.coredevice.reply")
        return await replyOrTimeout(within: openTimeoutSeconds, timedOut: nil, on: queue) { answer in
            xpc_connection_send_message_with_reply(service, request, queue) { answer($0) }
        }
    }

    func send(_ message: xpc_object_t) {
        traffic.noteSend()
        unsafe symbols.send(connection, message)
    }

    /// `handler` runs once on the socket's queue, with an XPC error if the connection dies first.
    func send(_ message: xpc_object_t, reply handler: @escaping @Sendable (xpc_object_t) -> Void) {
        traffic.noteSend()
        unsafe symbols.sendWithReply(connection, message, Unmanaged.passUnretained(queue).toOpaque()) { reply in handler(reply) }
    }

    func cancel() {
        unsafe symbols.cancel(connection)
    }
}

/// Counts the messages handed to one connection and marks where its first error and its invalidation were noticed, so a caller can tell that a message was handed over only after the connection had gone.
final class ConnectionTraffic: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private var ended: Int?
    private var invalidated: Int?

    var sentCount: Int { lock.withLock { sent } }
    var endedAfter: Int? { lock.withLock { ended } }
    var invalidatedAfter: Int? { lock.withLock { invalidated } }

    /// Counted before the message is handed over, so an error noticed at the same count came first.
    func noteSend() { lock.withLock { sent += 1 } }

    func noteError(invalidated isInvalidated: Bool) {
        lock.withLock {
            if ended == nil { ended = sent }
            if isInvalidated, invalidated == nil { invalidated = sent }
        }
    }
}

/// The private libxpc RemoteXPC calls and CoreDevice's XPC service registration, resolved at run time and never linked.
@unsafe struct RemoteXPC: @unchecked Sendable {
    typealias Create = @convention(c) (Int32, UnsafeMutableRawPointer, UInt64, UInt64) -> UnsafeMutableRawPointer?
    typealias SetEventHandler = @convention(c) (UnsafeMutableRawPointer, @escaping @convention(block) (xpc_object_t) -> Void) -> Void
    typealias Activate = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Send = @convention(c) (UnsafeMutableRawPointer, xpc_object_t) -> Void
    typealias SendWithReply = @convention(c) (UnsafeMutableRawPointer, xpc_object_t, UnsafeMutableRawPointer, @escaping @convention(block) (xpc_object_t) -> Void) -> Void
    typealias Cancel = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias AddBundle = @convention(c) (AnyObject) -> Void
    private typealias InitServices = @convention(c) () -> Void

    let create: Create
    let setEventHandler: SetEventHandler
    let activate: Activate
    let send: Send
    let sendWithReply: SendWithReply
    let cancel: Cancel
    /// CoreDeviceService is an XPC service inside CoreDevice.framework, found once the bundle is registered.
    let registered: Bool

    static let shared: RemoteXPC? = unsafe load()

    func serviceConnection() -> xpc_connection_t {
        let queue = DispatchQueue(label: "offsider.coredevice.service")
        let connection = unsafe registered
            ? xpc_connection_create(CoreDeviceServiceSocket.serviceName, queue)
            : xpc_connection_create_mach_service(CoreDeviceServiceSocket.serviceName, queue, 0)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        return connection
    }

    private static func load() -> RemoteXPC? {
        guard let handle = unsafe dlopen(nil, RTLD_NOW),
              let create = unsafe dlsym(handle, "xpc_remote_connection_create_with_connected_fd"),
              let setEventHandler = unsafe dlsym(handle, "xpc_remote_connection_set_event_handler"),
              let activate = unsafe dlsym(handle, "xpc_remote_connection_activate"),
              let send = unsafe dlsym(handle, "xpc_remote_connection_send_message"),
              let sendWithReply = unsafe dlsym(handle, "xpc_remote_connection_send_message_with_reply"),
              let cancel = unsafe dlsym(handle, "xpc_remote_connection_cancel") else {
            return nil
        }
        return unsafe RemoteXPC(
            create: unsafeBitCast(create, to: Create.self),
            setEventHandler: unsafeBitCast(setEventHandler, to: SetEventHandler.self),
            activate: unsafeBitCast(activate, to: Activate.self),
            send: unsafeBitCast(send, to: Send.self),
            sendWithReply: unsafeBitCast(sendWithReply, to: SendWithReply.self),
            cancel: unsafeBitCast(cancel, to: Cancel.self),
            registered: registerCoreDevice()
        )
    }

    private static func registerCoreDevice() -> Bool {
        let path = CoreDeviceVersion.frameworkPath
        guard let bundle = Bundle(path: path),
              let framework = unsafe dlopen(path + "/CoreDevice", RTLD_NOW),
              let addBundle = unsafe dlsym(framework, "_coredevice_xpc_add_bundle"),
              let initServices = unsafe dlsym(framework, "_coredevice_xpc_init_services") else {
            return false
        }
        unsafe unsafeBitCast(addBundle, to: AddBundle.self)(bundle)
        unsafe unsafeBitCast(initServices, to: InitServices.self)()
        return true
    }
}
