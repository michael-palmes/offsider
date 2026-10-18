import Foundation

/// The helper's framing, every op passed through but `hello`, `status`, `stop`, `health`, `screen` and `rememberScreen`, which the broker answers, and `quit`, which it refuses.
enum HelperBrokerWire {
    /// Part of the `hello` check: a broker from another build is stopped and replaced.
    static let protocolVersion = 2
    static let timeoutField = "brokerTimeoutMs"
    /// The largest request a command may send; replies may be as large as the helper's frames.
    static let maxRequestBytes = 1 << 20

    /// The fields of a command's request the broker reads; the rest pass through untouched.
    struct Request: Decodable, Equatable, Sendable {
        let id: Int
        let op: String
        let waitMs: Int?
        /// How long the command waits for this reply; the broker gives up on the helper at the same moment.
        let brokerTimeoutMs: Int?
        /// `rememberScreen`'s display facts, kept for later commands.
        var screen: String? = nil

        static func parse(_ payload: Data) -> Request? {
            try? JSONDecoder().decode(Request.self, from: payload)
        }
    }

    /// What `hello` adds to the helper's own `helper`, `protocol` and `ops`.
    struct Hello: Decodable, Equatable, Sendable {
        let brokerProtocol: Int
        let brokerPid: Int32
        let dexSha256: String
        let helperPid: Int32
        let sdkInt: Int
        let idleSeconds: Int
        /// The helper's start, ready line included, when the broker launched it.
        let launchMs: Int
        let pushed: Bool
        let eventSeq: Int64
        /// Other commands attached when this one said `hello`; absent from an earlier build's broker.
        var attached: Int? = nil
    }

    /// The `status` reply, read without counting as use.
    struct Status: Decodable, Equatable, Sendable {
        enum State: String, Decodable, Sendable {
            case starting
            case ready
            case stopping
        }

        let serial: String
        let state: State
        let brokerPid: Int32
        let helperPid: Int32?
        /// Seconds since 1970.
        let startedAt: Double
        let idleSeconds: Int
        /// Seconds since the last command's request.
        let idleFor: Int
        /// Commands connected after `hello`, which a stop would cut off; nil from a broker that does not say.
        let attached: Int?
        let helper: String?
        let `protocol`: Int?
        let sdkInt: Int?
        /// The helper's start, ready line included.
        let launchMs: Int?
        let pushed: Bool?
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func isOK(_ frame: Data) -> Bool {
        (try? JSONDecoder().decode(HelperEnvelope.self, from: frame))?.ok == true
    }

    static func ok(id: Int, fields: [String: HelperValue] = [:]) -> Data {
        object(fields.merging(["id": .int(id), "ok": .bool(true)]) { _, new in new })
    }

    static func helloReply(id: Int, helper: String, protocol number: Int, ops: [String], broker: Hello) -> Data {
        ok(id: id, fields: [
            "helper": .string(helper),
            "protocol": .int(number),
            "ops": .array(ops.map(HelperValue.string)),
            "brokerProtocol": .int(broker.brokerProtocol),
            "brokerPid": .int(Int(broker.brokerPid)),
            "dexSha256": .string(broker.dexSha256),
            "helperPid": .int(Int(broker.helperPid)),
            "sdkInt": .int(broker.sdkInt),
            "idleSeconds": .int(broker.idleSeconds),
            "launchMs": .int(broker.launchMs),
            "pushed": .bool(broker.pushed),
            "eventSeq": .int(Int(broker.eventSeq)),
            "attached": .int(broker.attached ?? 0),
        ])
    }

    static func statusReply(id: Int, _ status: Status) -> Data {
        var fields: [String: HelperValue] = [
            "serial": .string(status.serial),
            "state": .string(status.state.rawValue),
            "brokerPid": .int(Int(status.brokerPid)),
            "startedAt": .double(status.startedAt),
            "idleSeconds": .int(status.idleSeconds),
            "idleFor": .int(status.idleFor),
        ]
        fields["attached"] = status.attached.map(HelperValue.int)
        fields["helperPid"] = status.helperPid.map { .int(Int($0)) }
        fields["helper"] = status.helper.map(HelperValue.string)
        fields["protocol"] = status.protocol.map(HelperValue.int)
        fields["sdkInt"] = status.sdkInt.map(HelperValue.int)
        fields["launchMs"] = status.launchMs.map(HelperValue.int)
        fields["pushed"] = status.pushed.map(HelperValue.bool)
        return ok(id: id, fields: ["status": .object(fields)])
    }

    /// The `status` reply's body.
    struct StatusReply: Decodable, Sendable {
        let status: Status
    }

    /// The `health` reply's body: the helper's ping through the broker.
    struct HealthReply: Decodable, Sendable {
        let pingMs: Int
    }

    /// `stop`'s reply: `starting` when the helper had not started yet, so the broker stops once its start ends.
    struct StopReply: Decodable, Sendable {
        let starting: Bool?
    }

    /// The `screen` reply's body: the display facts a command left, absent when none or the helper has gone.
    struct ScreenReply: Decodable, Sendable {
        let screen: String?
    }

    static func error(id: Int, code: String, message: String, extra: [String: HelperValue] = [:]) -> Data {
        let body = extra.merging(["code": .string(code), "message": .string(message)]) { _, new in new }
        return object(["id": .int(id), "ok": .bool(false), "error": .object(body)])
    }

    static func bye(reason: String, detail: String?) -> Data {
        var fields: [String: HelperValue] = ["event": .string("bye"), "reason": .string(reason)]
        fields["detail"] = detail.map(HelperValue.string)
        return object(fields)
    }

    /// The helper could not start: busy and unavailable keep their reason, so the command falls back exactly as with its own helper.
    static func startFailure(id: Int, _ failure: HelperStartFailure) -> Data {
        switch failure {
        case .busy(let detail):
            return error(id: id, code: Code.busy, message: "another UiAutomation client holds the slot", extra: ["detail": .string(detail)])
        case .unavailable(let reason):
            var extra: [String: HelperValue] = ["reason": .string(reason.wireKind)]
            extra["detail"] = reason.wireDetail.map(HelperValue.string)
            extra["status"] = reason.wireNumber.map(HelperValue.int)
            return error(id: id, code: Code.unavailable, message: reason.description, extra: extra)
        }
    }

    enum Code {
        static let busy = "helper-busy"
        static let unavailable = "helper-unavailable"
        /// The broker could not start its helper for a reason of the device's; the command starts its own, which reports it.
        static let startFailed = "start-failed"
        /// The broker is stopping, or its helper has gone; the command starts a fresh broker.
        static let ended = "broker-ended"
        static let badRequest = "bad-request"
        static let refused = "refused"
    }

    /// The error a failed `hello` carries, with the start failure's reason.
    struct ErrorReply: Decodable, Equatable, Sendable {
        struct Body: Decodable, Equatable, Sendable {
            let code: String
            let message: String
            let detail: String?
            let reason: String?
            let status: Int?
        }

        let error: Body

        var startFailure: HelperStartFailure? {
            switch error.code {
            case Code.busy:
                return .busy(detail: error.detail ?? error.message)
            case Code.unavailable:
                return HelperUnavailableReason(wireKind: error.reason, detail: error.detail ?? error.message, number: error.status).map(HelperStartFailure.unavailable)
            default:
                return nil
            }
        }
    }

    private static func object(_ fields: [String: HelperValue]) -> Data {
        (try? encoder.encode(fields)) ?? Data("{}".utf8)
    }
}

extension HelperUnavailableReason {
    var wireKind: String {
        switch self {
        case .notBundled: return "notBundled"
        case .damaged: return "damaged"
        case .pushFailed: return "pushFailed"
        case .hiddenAPI: return "hiddenAPI"
        case .connectFailed: return "connectFailed"
        case .crashed: return "crashed"
        case .noReady: return "noReady"
        case .handshake: return "handshake"
        case .forcedOff: return "forcedOff"
        }
    }

    var wireDetail: String? {
        switch self {
        case .notBundled(let detail), .damaged(let detail), .pushFailed(let detail), .hiddenAPI(let detail),
             .connectFailed(let detail), .handshake(let detail), .crashed(_, let detail):
            return detail
        case .noReady, .forcedOff:
            return nil
        }
    }

    var wireNumber: Int? {
        switch self {
        case .crashed(let status, _): return Int(status)
        case .noReady(let seconds): return seconds
        default: return nil
        }
    }

    init?(wireKind: String?, detail: String, number: Int?) {
        switch wireKind {
        case "notBundled": self = .notBundled(detail)
        case "damaged": self = .damaged(detail)
        case "pushFailed": self = .pushFailed(detail)
        case "hiddenAPI": self = .hiddenAPI(detail)
        case "connectFailed": self = .connectFailed(detail)
        case "crashed": self = .crashed(status: Int32(clamping: number ?? 0), detail: detail)
        case "noReady": self = .noReady(seconds: number ?? 0)
        case "handshake": self = .handshake(detail)
        case "forcedOff": self = .forcedOff
        default: return nil
        }
    }
}

extension HelperBrokerWire.Status {
    private enum CodingKeys: String, CodingKey {
        case serial, state, brokerPid, helperPid, startedAt, idleSeconds, idleFor, attached, helper, `protocol`, sdkInt, launchMs, pushed
    }

    /// Only `serial`, `state` and `brokerPid` are required, so a broker of another build still reads and stops.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serial = try container.decode(String.self, forKey: .serial)
        state = try container.decode(State.self, forKey: .state)
        brokerPid = try container.decode(Int32.self, forKey: .brokerPid)
        helperPid = try? container.decodeIfPresent(Int32.self, forKey: .helperPid)
        startedAt = (try? container.decodeIfPresent(Double.self, forKey: .startedAt)) ?? 0
        idleSeconds = (try? container.decodeIfPresent(Int.self, forKey: .idleSeconds)) ?? 0
        idleFor = (try? container.decodeIfPresent(Int.self, forKey: .idleFor)) ?? 0
        attached = try? container.decodeIfPresent(Int.self, forKey: .attached)
        helper = try? container.decodeIfPresent(String.self, forKey: .helper)
        `protocol` = try? container.decodeIfPresent(Int.self, forKey: .protocol)
        sdkInt = try? container.decodeIfPresent(Int.self, forKey: .sdkInt)
        launchMs = try? container.decodeIfPresent(Int.self, forKey: .launchMs)
        pushed = try? container.decodeIfPresent(Bool.self, forKey: .pushed)
    }
}
