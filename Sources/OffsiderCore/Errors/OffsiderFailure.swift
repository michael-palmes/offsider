import Foundation

/// Whether input may have reached the device when a command failed.
public enum DispatchState: String, Sendable {
    case no
    case unknown
    case yes
}

/// An element a failed selector could have meant; never carries the element's value.
public struct FailureCandidate: Equatable, Sendable {
    public let id: String?
    public let label: String?
    public let role: String
    public let frame: UIFrame?
    public let onScreen: Bool?
    /// The number `tap --nth` takes for it, among the on-screen matches.
    public let index: Int?
    /// The window or app title it is in.
    public let window: String?
    /// The id of the nearest screen-filling ancestor.
    public let screen: String?

    public init(id: String?, label: String?, role: String, frame: UIFrame?, onScreen: Bool?, index: Int? = nil, window: String? = nil, screen: String? = nil) {
        self.id = id
        self.label = label
        self.role = role
        self.frame = frame
        self.onScreen = onScreen
        self.index = index
        self.window = window
        self.screen = screen
    }

    var jsonValue: OrderedJSON {
        .object([
            ("id", .optional(id, OrderedJSON.string)),
            ("label", .optional(label, OrderedJSON.string)),
            ("role", .string(role)),
            ("frame", frame.map(\.jsonValue) ?? .null),
            ("onScreen", .optional(onScreen, OrderedJSON.bool)),
            ("index", .optional(index, OrderedJSON.integer)),
            ("window", .optional(window, OrderedJSON.string)),
            ("screen", .optional(screen, OrderedJSON.string)),
        ])
    }
}

/// A failure with a typed reason; `hint` is a command to run next and never echoes typed text.
public protocol OffsiderFailure: Error {
    var reason: FailureReason { get }
    var failureMessage: String { get }
    var hint: String? { get }
    var candidates: [FailureCandidate] { get }
}

extension OffsiderFailure {
    public var hint: String? { nil }
    public var candidates: [FailureCandidate] { [] }
    public var exitCode: OffsiderExitCode { reason.exitCode }
}
