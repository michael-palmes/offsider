import CoreMedia
import Darwin
import Foundation
import ObjectiveC
import XPC

/// Every private class, selector and option key the screen stream uses, reached through the Objective-C runtime and never linked.
enum MediaStreamSymbols {
    static let avConference = "/System/Library/PrivateFrameworks/AVConference.framework/AVConference"

    static let negotiatorClass = "AVCMediaStreamNegotiator"
    static let videoStreamClass = "AVCVideoStream"
    static let imageQueueClass = "VCImageQueue"
    static let streamOutputClass = "VCStreamOutput"

    static let alloc = "alloc"
    static let negotiatorInit = "initWithMode:options:error:"
    static let createOffer = "createOffer"
    static let offer = "offer"
    static let setAnswer = "setAnswer:withError:"
    static let configuration = "generateMediaStreamConfigurationWithError:"
    static let initOptions = "generateMediaStreamInitOptionsWithError:"
    static let videoStreamInit = "initWithNetworkSockets:options:error:"
    static let setDelegate = "setDelegate:"
    static let configure = "configure:error:"
    static let start = "start"
    static let stop = "stop"
    static let streamOutput = "streamOutput"
    static let setStreamOutput = "setStreamOutput:"
    static let streamToken = "streamToken"
    static let streamOutputInit = "initWithStreamToken:clientProcessID:delegate:delegateQueue:"

    /// `AVCMediaStreamNegotiatorMode` 5, CoreDeviceScreenSharing.
    static let screenSharingMode = 5
    static let sharedSocketKey = "avcKeySharedSocket"
    static let runInProcessKey = "avcMediaStreamOptionRunInProcess"
    static let clientNameKey = "avcMediaStreamOptionClientName"
    static let clientName = "CoreDeviceScreenSharing"
    static let sessionKey = "avcMediaStreamOptionClientSessionID"
}

/// A missing class or selector, or a private call that returned an error.
struct MediaStreamRuntimeError: Error, CustomStringConvertible {
    let description: String
}

private typealias ErrorOut = UnsafeMutablePointer<Unmanaged<NSError>?>

private enum Runtime {
    static func loadAVConference() throws {
        guard dlopen(MediaStreamSymbols.avConference, RTLD_NOW) != nil else {
            throw MediaStreamRuntimeError(description: "AVConference did not load: \(dlerror().map { String(cString: $0) } ?? "unknown")")
        }
    }

    static func type(_ name: String) throws -> AnyClass {
        guard let type = NSClassFromString(name) else { throw MediaStreamRuntimeError(description: "this macOS has no \(name)") }
        return type
    }

    static func implementation<F>(_ type: AnyClass, _ selector: String, as _: F.Type) throws -> F {
        guard class_respondsToSelector(type, NSSelectorFromString(selector)), let method = class_getMethodImplementation(type, NSSelectorFromString(selector)) else {
            throw MediaStreamRuntimeError(description: "\(NSStringFromClass(type)) has no \(selector)")
        }
        return unsafeBitCast(method, to: F.self)
    }

    static func implementation<F>(_ object: AnyObject, _ selector: String, as kind: F.Type) throws -> F {
        try implementation(object_getClass(object)!, selector, as: kind)
    }

    /// An `alloc`ed instance at +1, for an `init...` call to consume.
    static func alloc(_ type: AnyClass) throws -> UnsafeMutableRawPointer {
        typealias Alloc = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer
        let metaclass: AnyClass = object_getClass(type)!
        return try implementation(metaclass, MediaStreamSymbols.alloc, as: Alloc.self)(type, NSSelectorFromString(MediaStreamSymbols.alloc))
    }

    static func adopt(_ pointer: UnsafeMutableRawPointer?) -> AnyObject? {
        pointer.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
    }

    static func borrow(_ pointer: UnsafeMutableRawPointer?) -> AnyObject? {
        pointer.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }

    static func failure(_ what: String, _ error: Unmanaged<NSError>?) -> MediaStreamRuntimeError {
        MediaStreamRuntimeError(description: "\(what) failed" + (error.map { ": \($0.takeUnretainedValue().localizedDescription)" } ?? ""))
    }

    static func send(_ object: AnyObject, _ selector: String) throws {
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        try implementation(object, selector, as: Call.self)(object, NSSelectorFromString(selector))
    }

    static func get(_ object: AnyObject, _ selector: String) throws -> AnyObject? {
        typealias Call = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        return borrow(try implementation(object, selector, as: Call.self)(object, NSSelectorFromString(selector)))
    }

    static func set(_ object: AnyObject, _ selector: String, _ value: AnyObject) throws {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        try implementation(object, selector, as: Call.self)(object, NSSelectorFromString(selector), value)
    }
}

/// `AVCMediaStreamNegotiator` in screen sharing mode: builds the offer and reads the device's answer.
final class MediaStreamNegotiator {
    private let object: AnyObject

    init() throws {
        try Runtime.loadAVConference()
        typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector, Int, NSDictionary, ErrorOut?) -> UnsafeMutableRawPointer?
        let type: AnyClass = try Runtime.type(MediaStreamSymbols.negotiatorClass)
        let initialise = try Runtime.implementation(type, MediaStreamSymbols.negotiatorInit, as: Init.self)
        var error: Unmanaged<NSError>?
        let raw = try Runtime.alloc(type)
        guard let object = Runtime.adopt(initialise(raw, NSSelectorFromString(MediaStreamSymbols.negotiatorInit), MediaStreamSymbols.screenSharingMode, [:], &error)) else {
            throw Runtime.failure("creating the stream negotiator", error)
        }
        self.object = object
    }

    func offer() throws -> Data {
        typealias Create = @convention(c) (AnyObject, Selector) -> Bool
        guard try Runtime.implementation(object, MediaStreamSymbols.createOffer, as: Create.self)(object, NSSelectorFromString(MediaStreamSymbols.createOffer)),
              let offer = try Runtime.get(object, MediaStreamSymbols.offer) as? Data, !offer.isEmpty else {
            throw MediaStreamRuntimeError(description: "the stream negotiator made no offer")
        }
        return offer
    }

    /// The configuration and init options `AVCVideoStream` takes once the answer is set.
    func accept(_ answer: Data) throws -> (configuration: AnyObject, options: [String: Any]) {
        typealias SetAnswer = @convention(c) (AnyObject, Selector, NSData, ErrorOut?) -> Bool
        typealias Generate = @convention(c) (AnyObject, Selector, ErrorOut?) -> UnsafeMutableRawPointer?
        var error: Unmanaged<NSError>?
        guard try Runtime.implementation(object, MediaStreamSymbols.setAnswer, as: SetAnswer.self)(object, NSSelectorFromString(MediaStreamSymbols.setAnswer), answer as NSData, &error) else {
            throw Runtime.failure("reading the device's stream answer", error)
        }
        func generate(_ selector: String) throws -> AnyObject {
            guard let value = Runtime.borrow(try Runtime.implementation(object, selector, as: Generate.self)(object, NSSelectorFromString(selector), &error)) else {
                throw Runtime.failure(selector, error)
            }
            return value
        }
        let configuration = try generate(MediaStreamSymbols.configuration)
        let options = try generate(MediaStreamSymbols.initOptions) as? [String: Any] ?? [:]
        return (configuration, options)
    }
}

/// `AVCVideoStream` decoding in this process over our own connected UDP socket; needs a window server for its display link.
final class MediaVideoStream {
    private let object: AnyObject
    private let delegate: MediaStreamDelegate

    init(socket: Int32, options: [String: Any], session: UUID, delegate: MediaStreamDelegate) throws {
        typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject, NSDictionary, ErrorOut?) -> UnsafeMutableRawPointer?
        var merged = options
        merged[MediaStreamSymbols.runInProcessKey] = true
        merged[MediaStreamSymbols.clientNameKey] = MediaStreamSymbols.clientName
        merged[MediaStreamSymbols.sessionKey] = session
        let sockets = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_fd(sockets, MediaStreamSymbols.sharedSocketKey, socket)
        let type: AnyClass = try Runtime.type(MediaStreamSymbols.videoStreamClass)
        let initialise = try Runtime.implementation(type, MediaStreamSymbols.videoStreamInit, as: Init.self)
        var error: Unmanaged<NSError>?
        let raw = try Runtime.alloc(type)
        guard let object = Runtime.adopt(initialise(raw, NSSelectorFromString(MediaStreamSymbols.videoStreamInit), sockets, merged as NSDictionary, &error)) else {
            throw Runtime.failure("creating the video stream", error)
        }
        self.object = object
        self.delegate = delegate
        try Runtime.set(object, MediaStreamSymbols.setDelegate, delegate)
    }

    func configure(_ configuration: AnyObject) throws {
        typealias Configure = @convention(c) (AnyObject, Selector, AnyObject, ErrorOut?) -> Bool
        var error: Unmanaged<NSError>?
        guard try Runtime.implementation(object, MediaStreamSymbols.configure, as: Configure.self)(object, NSSelectorFromString(MediaStreamSymbols.configure), configuration, &error) else {
            throw Runtime.failure("configuring the video stream", error)
        }
    }

    /// Frames reach `delegate` through the image queue tap from here on.
    func start() throws {
        try ImageQueueTap.install()
        ImageQueueTap.arm(delegate)
        try Runtime.send(object, MediaStreamSymbols.start)
    }

    func stop() {
        try? Runtime.send(object, MediaStreamSymbols.stop)
        ImageQueueTap.disarm(delegate)
    }
}

/// Receives the stream's lifecycle callbacks and, through `VCStreamOutput`, every decoded sample buffer.
final class MediaStreamDelegate: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "offsider.stream.frames", qos: .userInitiated)
    private let onFrame: @Sendable (CMSampleBuffer) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(onFrame: @escaping @Sendable (CMSampleBuffer) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    @objc(streamOutput:didReceiveSampleBuffer:)
    func streamOutput(_ output: AnyObject, didReceive buffer: CMSampleBuffer) { onFrame(buffer) }

    @objc(didReceiveSampleBuffer:)
    func didReceive(_ buffer: CMSampleBuffer) { onFrame(buffer) }

    @objc(stream:didStart:error:)
    func stream(_ stream: AnyObject, didStart started: Bool, error: NSError?) {
        if !started { onFailure("the video stream did not start" + (error.map { ": \($0.localizedDescription)" } ?? "")) }
    }

    @objc(streamDidServerDie:)
    func streamDidServerDie(_ stream: AnyObject) { onFailure("the media server closed the stream") }

    @objc(streamDidStop:)
    func streamDidStop(_ stream: AnyObject) {}

    @objc(vcMediaStreamDidStop:)
    func vcMediaStreamDidStop(_ stream: AnyObject) {}

    @objc(stream:didGetLastDecodedFrame:)
    func stream(_ stream: AnyObject, didGetLastDecodedFrame frame: AnyObject) {}
}

/// Gives each `VCImageQueue` a `VCStreamOutput` aimed at the armed delegate as it starts, which is how in-process frames reach us.
enum ImageQueueTap {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var armed: MediaStreamDelegate?
    nonisolated(unsafe) private static var original: IMP?

    static func arm(_ delegate: MediaStreamDelegate) {
        lock.withLock { armed = delegate }
    }

    static func disarm(_ delegate: MediaStreamDelegate) {
        lock.withLock { if armed === delegate { armed = nil } }
    }

    static func install() throws {
        try lock.withLock {
            guard !installed else { return }
            let type: AnyClass = try Runtime.type(MediaStreamSymbols.imageQueueClass)
            for selector in [MediaStreamSymbols.streamOutput, MediaStreamSymbols.setStreamOutput, MediaStreamSymbols.streamToken] {
                _ = try Runtime.implementation(type, selector, as: IMP.self)
            }
            _ = try Runtime.implementation(try Runtime.type(MediaStreamSymbols.streamOutputClass), MediaStreamSymbols.streamOutputInit, as: IMP.self)
            guard let method = class_getInstanceMethod(type, NSSelectorFromString(MediaStreamSymbols.start)) else {
                throw MediaStreamRuntimeError(description: "\(MediaStreamSymbols.imageQueueClass) has no \(MediaStreamSymbols.start)")
            }
            original = method_getImplementation(method)
            let replacement: @convention(block) (AnyObject) -> Void = { queue in
                ImageQueueTap.attach(to: queue)
                typealias Start = @convention(c) (AnyObject, Selector) -> Void
                if let original = ImageQueueTap.lock.withLock({ ImageQueueTap.original }) {
                    unsafeBitCast(original, to: Start.self)(queue, NSSelectorFromString(MediaStreamSymbols.start))
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            installed = true
        }
    }

    private static func attach(to queue: AnyObject) {
        typealias Token = @convention(c) (AnyObject, Selector) -> Int64
        typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector, Int64, Int32, AnyObject, DispatchQueue) -> UnsafeMutableRawPointer?
        guard let delegate = lock.withLock({ armed }), (try? Runtime.get(queue, MediaStreamSymbols.streamOutput)) == nil else { return }
        guard let type: AnyClass = try? Runtime.type(MediaStreamSymbols.streamOutputClass),
              let token = try? Runtime.implementation(queue, MediaStreamSymbols.streamToken, as: Token.self)(queue, NSSelectorFromString(MediaStreamSymbols.streamToken)),
              let initialise = try? Runtime.implementation(type, MediaStreamSymbols.streamOutputInit, as: Init.self),
              let raw = try? Runtime.alloc(type),
              let output = Runtime.adopt(initialise(raw, NSSelectorFromString(MediaStreamSymbols.streamOutputInit), token, getpid(), delegate, delegate.queue)) else {
            return
        }
        try? Runtime.set(queue, MediaStreamSymbols.setStreamOutput, output)
    }
}
