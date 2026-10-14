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

/// Checks a private method's Objective-C type encoding before its implementation is cast to a Swift function type, so a changed signature fails cleanly instead of corrupting memory.
public enum PrivateAPIGuard {
    /// The encoding without its frame offsets, e.g. `@28@0:8@16I24` becomes `@@:@I`.
    public static func strippedEncoding(_ encoding: String) -> String {
        encoding.filter { !$0.isNumber }
    }

    /// The method's encoding with offsets removed; nil when `type` has no such method. Pass the metaclass for a class method.
    public static func encoding(of type: AnyClass, _ selector: Selector) -> String? {
        guard let method = class_getInstanceMethod(type, selector), let raw = method_getTypeEncoding(method) else { return nil }
        return strippedEncoding(String(cString: raw))
    }

    /// Throws `PrivateAPIChanged` unless `type` has `selector` with exactly `expected` (offsets ignored).
    public static func requireMethod(_ type: AnyClass, _ selector: Selector, encoding expected: String, framework: String, owner: String = "Xcode") throws {
        guard encoding(of: type, selector) == strippedEncoding(expected) else {
            throw PrivateAPIChanged(framework: framework, selector: NSStringFromSelector(selector), owner: owner)
        }
    }
}
