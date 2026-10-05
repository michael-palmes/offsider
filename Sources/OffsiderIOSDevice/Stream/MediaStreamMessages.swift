import Darwin
import Foundation

/// An XPC value as the media stream actions carry it, kept apart from libxpc so replies parse in tests.
indirect enum MediaStreamValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case data(Data)
    case uuid(UUID)
    case array([MediaStreamValue])
    case dictionary([String: MediaStreamValue])

    subscript(key: String) -> MediaStreamValue? {
        guard case .dictionary(let entries) = self else { return nil }
        return entries[key]
    }

    var unsigned: UInt64? {
        switch self {
        case .uint(let value): return value
        case .int(let value) where value >= 0: return UInt64(value)
        default: return nil
        }
    }

    var text: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bytes: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    var flag: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

/// The device's `dtremotedisplayd` actions, each sent once on its own feature socket.
enum MediaStreamAction {
    static let startFeature = "com.apple.coredevice.feature.startmediastream"
    static let start = "com.apple.coredevice.action.mediastreamstart"
    static let stopFeature = "com.apple.coredevice.feature.stopmediastream"
    static let stop = "com.apple.coredevice.action.mediastreamstop"
    static let statusFeature = "com.apple.coredevice.feature.getmediastreamserverstatus"
    static let status = "com.apple.coredevice.action.mediastreamstatus"

    /// The feature bits and sender port Xcode's screen sharing sends, as ipb captured them.
    static let clientSupportedFeatures: UInt64 = 972
    static let senderPort: UInt64 = 51000
    static let negotiationTimeoutSeconds: UInt64 = 30

    /// One video stream of the main display to `receiver`, which must already be bound.
    static func startInput(receiverIP: String, receiverPort: UInt16, senderIP: String, offer: Data, session: UUID) -> MediaStreamValue {
        .dictionary([
            "receiverIP": .string(receiverIP),
            "receiverPort": .uint(UInt64(receiverPort)),
            "senderIP": .string(senderIP),
            "senderPort": .uint(senderPort),
            "timeout": .uint(negotiationTimeoutSeconds),
            "type": .string("video"),
            "direction": .string("output"),
            "negotiatorOffer": .data(offer),
            "clientSupportedFeatures": .uint(clientSupportedFeatures),
            "options": .dictionary(["avcMediaStreamOptionClientSessionID": .dictionary(["uuid": .uuid(session)])]),
        ])
    }

    /// Stops only the session `identifier` names, so a Device Hub mirror of the same device keeps running.
    static func stopInput(identifier: UInt32) -> MediaStreamValue {
        .dictionary(["stopAll": .bool(false), "identifiers": .array([.uint(UInt64(identifier))])])
    }
}

/// What `mediastreamstart` answers, from its `CoreDevice.output`.
struct MediaStreamAnswer: Equatable, Sendable {
    struct ParseError: Error, Equatable, Sendable {
        let detail: String
    }

    let negotiatorAnswer: Data
    /// The session's `RemoteSSRC`, which `mediastreamstop` takes as its identifier.
    let identifier: UInt32
    let session: UUID?
    let width: Int
    let height: Int
    let frameRate: Int?
    let senderPort: UInt16?

    static func parse(_ output: MediaStreamValue) throws -> MediaStreamAnswer {
        guard let answer = (output["negotiatorAnswer"] ?? output["answer"])?.bytes, !answer.isEmpty else {
            throw ParseError(detail: "no negotiator answer")
        }
        guard let config = output["connection"]?["streamConfig"] else {
            throw ParseError(detail: "no stream configuration")
        }
        guard let ssrc = config["RemoteSSRC"]?.unsigned, let identifier = UInt32(exactly: ssrc) else {
            throw ParseError(detail: "no session identifier")
        }
        guard let width = config["CustomWidth"]?.unsigned, let height = config["CustomHeight"]?.unsigned, width > 0, height > 0 else {
            throw ParseError(detail: "no stream size")
        }
        var session: UUID?
        if case .uuid(let value)? = output["connection"]?["options"]?["avcMediaStreamOptionClientSessionID"]?["uuid"] {
            session = value
        }
        return MediaStreamAnswer(
            negotiatorAnswer: answer,
            identifier: identifier,
            session: session,
            width: Int(width),
            height: Int(height),
            frameRate: config["Framerate"]?.unsigned.map { Int($0) },
            senderPort: output["connection"]?["sender"]?["port"]?.unsigned.flatMap { UInt16(exactly: $0) }
        )
    }
}

/// `mediastreamstatus` and the `serverInfo` a stop answers with: which sessions the device still runs.
struct MediaStreamServerStatus: Equatable, Sendable {
    let running: Bool
    let identifiers: [UInt32]

    static func parse(_ output: MediaStreamValue) -> MediaStreamServerStatus {
        let info = output["serverInfo"] ?? output
        var identifiers: [UInt32] = []
        if case .array(let sessions)? = info["sessions"] {
            identifiers = sessions.compactMap { $0["connection"]?["streamConfig"]?["RemoteSSRC"]?.unsigned.flatMap { UInt32(exactly: $0) } }
        }
        return MediaStreamServerStatus(running: info["running"]?.flag ?? false, identifiers: identifiers)
    }
}

/// The Mac's end of the CoreDevice tunnel: the `utun` address sharing the device's /64, so RTP never binds a LAN interface.
enum TunnelEndpoint {
    struct Interface: Equatable, Sendable {
        let name: String
        let address: String
    }

    static func host(forDevice device: String, among interfaces: [Interface]) -> Interface? {
        guard let target = bytes(device) else { return nil }
        return interfaces.first { candidate in
            guard candidate.name.hasPrefix("utun"), let address = bytes(candidate.address) else { return false }
            return address.prefix(8) == target.prefix(8) && address != target
        }
    }

    static func bytes(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// Every IPv6 address on this Mac with its interface name.
    static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var found: [Interface] = []
        var cursor = list
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let socket = entry.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var address = UnsafeRawPointer(socket).load(as: sockaddr_in6.self).sin6_addr
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { continue }
            found.append(Interface(name: String(cString: entry.pointee.ifa_name), address: String(cString: buffer)))
        }
        return found
    }
}

/// Holds only the newest decoded frame; a frame whose timestamp does not advance is dropped.
struct LatestFrameSlot<Frame> {
    private(set) var frame: Frame?
    private(set) var received = 0
    private var newest: Double?

    @discardableResult
    mutating func offer(_ frame: Frame, timestamp: Double) -> Bool {
        guard timestamp.isFinite else { return false }
        if let newest, timestamp <= newest { return false }
        newest = timestamp
        self.frame = frame
        received += 1
        return true
    }
}

/// `backboardd` re-matches HID services against a new stream about 0.3 s after the start is answered.
enum MediaStreamReadiness {
    static let settle: Duration = .milliseconds(300)

    static func remaining(answeredAt: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Duration {
        max(.zero, settle - (now - answeredAt))
    }
}
