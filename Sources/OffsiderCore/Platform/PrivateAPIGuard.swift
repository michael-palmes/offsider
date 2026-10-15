import Foundation
import ObjectiveC

/// A private method Offsider calls through a cast function pointer no longer has the types it was built against.
public struct PrivateAPIChanged: OffsiderFailure, LocalizedError, Equatable, Sendable {
    public let framework: String
    public let selector: String
    /// "Xcode" for simulator frameworks, "macOS" for the system's own.
    public let owner: String

    public init(framework: String, selector: String, owner: String = "Xcode") {
        self.framework = framework
        self.selector = selector
        self.owner = owner
    }

    public var reason: FailureReason { .xcodeUnusable }
    public var failureMessage: String { "This \(owner)'s \(framework) changed \(selector); update Offsider." }
    public var errorDescription: String? { failureMessage }
}

/// A private method Offsider was about to cast with no recorded type encoding: a bug in Offsider, refused rather than called blind.
public struct PrivateAPIUnrecorded: OffsiderFailure, LocalizedError, Equatable, Sendable {
    public let framework: String
    public let selector: String

    public init(framework: String, selector: String) {
        self.framework = framework
        self.selector = selector
    }

    public var reason: FailureReason { .xcodeUnusable }
    public var failureMessage: String { "Offsider has no recorded types for \(framework)'s \(selector), so it will not call it; update Offsider." }
    public var errorDescription: String? { failureMessage }
}

/// Checks a private method's Objective-C type encoding before its implementation is cast to a Swift function type, so a changed signature fails cleanly instead of corrupting memory.
public enum PrivateAPIGuard {
    /// The encoding without its frame offsets, e.g. `@28@0:8@16I24` becomes `@@:@I`; array sizes, bitfield widths and names keep their digits.
    public static func strippedEncoding(_ encoding: String) -> String {
        var stripped = ""
        var keepsDigits = false
        var inQuotes = false
        var inName = false
        for character in encoding {
            if inQuotes {
                stripped.append(character)
                inQuotes = character != "\""
                continue
            }
            if inName {
                stripped.append(character)
                inName = !"=})".contains(character)
                continue
            }
            if character.isASCII, character.isNumber {
                if keepsDigits { stripped.append(character) }
                continue
            }
            stripped.append(character)
            switch character {
            case "\"": inQuotes = true
            case "{", "(": inName = true
            default: break
            }
            keepsDigits = character == "[" || character == "b"
        }
        return stripped
    }

    /// The method's encoding with offsets removed; nil when `type` has no such method. Pass the metaclass for a class method.
    public static func encoding(of type: AnyClass, _ selector: Selector) -> String? {
        guard let method = unsafe class_getInstanceMethod(type, selector), let raw = unsafe method_getTypeEncoding(method) else { return nil }
        return unsafe strippedEncoding(String(cString: raw))
    }

    /// The encoding `table` records for `selector`; a selector with none throws `PrivateAPIUnrecorded`, so nothing is cast unchecked.
    public static func recordedEncoding(_ selector: String, in table: [String: String], framework: String) throws -> String {
        guard let encoding = table[selector] else { throw PrivateAPIUnrecorded(framework: framework, selector: selector) }
        return encoding
    }

    /// The encoding `protocolName` declares for a required instance `selector`, offsets removed; nil when either is missing.
    public static func encoding(inProtocol protocolName: String, _ selector: Selector) -> String? {
        guard let declared = unsafe objc_getProtocol(protocolName) else { return nil }
        let description = unsafe protocol_getMethodDescription(declared, selector, true, true)
        return unsafe description.types.map { unsafe strippedEncoding(String(cString: $0)) }
    }

    /// For an object that may be a proxy: its class's method when it has one, and always the encoding `protocolName` declares, must both match.
    public static func requireMessage(
        to object: AnyObject, _ selector: Selector, encoding expected: String, protocol protocolName: String, framework: String, owner: String = "Xcode"
    ) throws {
        let wanted = strippedEncoding(expected)
        let changed = PrivateAPIChanged(framework: framework, selector: NSStringFromSelector(selector), owner: owner)
        guard encoding(inProtocol: protocolName, selector) == wanted else { throw changed }
        if let type = object_getClass(object), unsafe class_getInstanceMethod(type, selector) != nil, encoding(of: type, selector) != wanted {
            throw changed
        }
    }

    /// Throws `PrivateAPIChanged` unless `type` has `selector` with exactly `expected` (offsets ignored).
    public static func requireMethod(_ type: AnyClass, _ selector: Selector, encoding expected: String, framework: String, owner: String = "Xcode") throws {
        guard encoding(of: type, selector) == strippedEncoding(expected) else {
            throw PrivateAPIChanged(framework: framework, selector: NSStringFromSelector(selector), owner: owner)
        }
    }
}
