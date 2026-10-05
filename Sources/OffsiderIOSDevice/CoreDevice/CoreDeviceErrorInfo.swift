import Foundation
import OffsiderCore
import XPC

/// An NSError as CoreDeviceService and RemoteXPC replies carry it: a dictionary of domain, code and user info.
public struct CoreDeviceErrorInfo: Equatable, Sendable {
    public var domain: String
    public var code: Int
    public var description: String?
    public var underlying: [CoreDeviceErrorInfo]

    public init(domain: String, code: Int, description: String? = nil, underlying: [CoreDeviceErrorInfo] = []) {
        self.domain = domain
        self.code = code
        self.description = description
        self.underlying = underlying
    }

    /// This error and every error beneath it.
    public var chain: [CoreDeviceErrorInfo] {
        [self] + underlying.flatMap(\.chain)
    }

    /// RemotePairingError 1016, `unlockRequired`, anywhere in the chain.
    public var isLocked: Bool {
        chain.contains { $0.domain.contains("RemotePairing") && $0.code == 1016 }
    }

    /// The Xcode 26 disk image has no HID daemon, so CoreDevice refuses the feature outright.
    public var isFeatureUnsupported: Bool {
        chain.contains { $0.description?.localizedCaseInsensitiveContains("not supported by this device") == true }
    }

    public var isTunnelDown: Bool {
        chain.contains { $0.domain == "com.apple.dt.CoreDeviceError" && $0.code == 4000 }
    }

    /// The first description in the chain, else the domain and code.
    public var summary: String {
        chain.compactMap(\.description).first ?? "\(domain) \(code)"
    }

    /// Nil when `object` is not an error dictionary.
    public init?(xpc object: xpc_object_t) {
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY, let domain = xpc_dictionary_get_string(object, "domain") else { return nil }
        self.domain = String(cString: domain)
        code = Int(Self.integer(xpc_dictionary_get_value(object, "code")) ?? 0)
        var description: String?
        var underlying: [CoreDeviceErrorInfo] = []
        if let info = xpc_dictionary_get_value(object, "userInfo"), xpc_get_type(info) == XPC_TYPE_DICTIONARY {
            description = Self.string(info, "NSLocalizedDescription") ?? Self.string(info, "NSDebugDescription")
                ?? Self.string(info, "NSLocalizedFailureReason")
            if let nested = xpc_dictionary_get_value(info, "NSUnderlyingError"), let error = CoreDeviceErrorInfo(xpc: nested) {
                underlying.append(error)
            }
            if let many = xpc_dictionary_get_value(info, "NSMultipleUnderlyingErrorsKey"), xpc_get_type(many) == XPC_TYPE_ARRAY {
                for index in 0..<xpc_array_get_count(many) {
                    if let error = CoreDeviceErrorInfo(xpc: xpc_array_get_value(many, index)) { underlying.append(error) }
                }
            }
        }
        self.description = description
        self.underlying = underlying
    }

    private static func string(_ dictionary: xpc_object_t, _ key: String) -> String? {
        xpc_dictionary_get_string(dictionary, key).map { String(cString: $0) }
    }

    private static func integer(_ value: xpc_object_t?) -> Int64? {
        guard let value else { return nil }
        let type = xpc_get_type(value)
        if type == XPC_TYPE_INT64 { return xpc_int64_get_value(value) }
        if type == XPC_TYPE_UINT64 { return Int64(truncatingIfNeeded: xpc_uint64_get_value(value)) }
        return nil
    }
}

/// What `dtuhidd` said to a message sent with a reply.
public enum DTUHIDReply: Equatable, Sendable {
    case answered
    case refused(CoreDeviceErrorInfo)
    case connectionLost(String)
    case timedOut

    /// A dictionary reply with an error under any key containing "error" is a refusal; XPC errors mean the connection died.
    public init(xpc reply: xpc_object_t) {
        let type = xpc_get_type(reply)
        if type == XPC_TYPE_ERROR {
            let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) }
            self = .connectionLost(description ?? "the connection closed")
            return
        }
        guard type == XPC_TYPE_DICTIONARY else {
            self = .answered
            return
        }
        var refusal: CoreDeviceErrorInfo?
        xpc_dictionary_apply(reply) { key, value in
            let name = String(cString: key)
            guard name.localizedCaseInsensitiveContains("error") else { return true }
            if let error = CoreDeviceErrorInfo(xpc: value) {
                refusal = error
            } else if xpc_get_type(value) == XPC_TYPE_STRING, let text = xpc_string_get_string_ptr(value) {
                refusal = CoreDeviceErrorInfo(domain: name, code: 0, description: String(cString: text))
            } else {
                return true
            }
            return false
        }
        self = refusal.map(DTUHIDReply.refused) ?? .answered
    }
}

extension IOSDeviceError {
    /// A failure before this event's first message; earlier events in the same command may still have landed.
    static func nothingSent(_ sent: Bool) -> String {
        sent ? "this input was not sent, though earlier input in this command may have reached it" : "no input was sent"
    }

    static func locked(_ name: String, udid: String, sent: Bool) -> IOSDeviceError {
        IOSDeviceError(.locked, "\(name) is locked, so \(nothingSent(sent)). Unlock the iPhone or iPad and retry; Offsider never types a passcode. `offsider doctor --device \(udid)` shows its state.")
    }

    static func uiAutomationOff(_ name: String, udid: String, sent: Bool) -> IOSDeviceError {
        IOSDeviceError(
            .uiAutomationOff,
            "\(name) refused input while unlocked, so UI Automation is probably off and \(nothingSent(sent)). Turn it on in Settings > Developer > UI Automation, then retry; `offsider doctor --device \(udid)` checks it."
        )
    }

    static func xcodeTooOld(_ name: String, version: CoreDeviceVersion?) -> IOSDeviceError {
        let installed = version.map { "this Mac has CoreDevice \($0)" } ?? "this Mac has no CoreDevice"
        return IOSDeviceError(
            .xcodeTooOld,
            "Input on \(name) needs Xcode 27 (CoreDevice \(CoreDeviceVersion.hidFloor) or later), and \(installed). Install Xcode 27 for HID input, then select it with `xcode-select -s <Xcode.app>/Contents/Developer`."
        )
    }

    static func notSupportedOnDevice(_ what: String, instead: String) -> IOSDeviceError {
        IOSDeviceError(.notSupported, "\(what) is not supported on a physical iPhone or iPad. \(instead)")
    }

    static func hidFailed(_ name: String, udid: String, detail: String, sent: Bool) -> IOSDeviceError {
        let outcome = sent ? "Some input may have reached it." : "No input was sent."
        return IOSDeviceError(.hidFailed, "HID input to \(name) failed: \(detail). \(outcome) Retry; if it persists, run `offsider doctor --device \(udid)`.")
    }

    /// CoreDeviceService refused to open a feature socket.
    static func serviceSocket(_ error: CoreDeviceErrorInfo, feature: String, name: String, udid: String, sent: Bool) -> IOSDeviceError {
        if error.isLocked { return locked(name, udid: udid, sent: sent) }
        if error.isFeatureUnsupported { return xcodeTooOld(name, version: nil) }
        if error.isTunnelDown {
            return IOSDeviceError(.hidFailed, "The CoreDevice tunnel to \(name) is down, so \(nothingSent(sent)). Reconnect its cable and unlock it, then retry; `offsider doctor --device \(udid)` shows its state.")
        }
        return hidFailed(name, udid: udid, detail: "CoreDevice did not open \(feature): \(error.summary)", sent: sent)
    }

    /// The first barrier on a fresh socket was refused: locked if the error says so, else UI Automation is off.
    static func barrierRefused(_ error: CoreDeviceErrorInfo, name: String, udid: String, sent: Bool) -> IOSDeviceError {
        error.isLocked ? locked(name, udid: udid, sent: sent) : uiAutomationOff(name, udid: udid, sent: sent)
    }
}
