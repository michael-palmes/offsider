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
    /// The screen it is on: a covered screen's or page's name, else the id of the nearest screen-filling ancestor.
    public let screen: String?
    /// True when a page is drawn over its screen; nil when no page covers anything.
    public let beneath: Bool?

    public init(id: String?, label: String?, role: String, frame: UIFrame?, onScreen: Bool?, index: Int? = nil, window: String? = nil, screen: String? = nil, beneath: Bool? = nil) {
        self.id = id
        self.label = label
        self.role = role
        self.frame = frame
        self.onScreen = onScreen
        self.index = index
        self.window = window
        self.screen = screen
        self.beneath = beneath
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
            ("beneath", .optional(beneath, OrderedJSON.bool)),
        ])
    }
}

/// What a refused tap would have landed on, and how Offsider knew; never a value.
public struct CoverReport: Equatable, Sendable {
    public let role: String
    public let id: String?
    public let label: String?
    public let frame: UIFrame?
    /// The page or covered screen it is on.
    public let screen: String?
    public let evidence: CoverEvidence

    public init(role: String, id: String?, label: String?, frame: UIFrame?, screen: String?, evidence: CoverEvidence) {
        self.role = role
        self.id = id
        self.label = label
        self.frame = frame
        self.screen = screen
        self.evidence = evidence
    }

    public init(_ verdict: CoverVerdict) {
        self.init(
            role: verdict.cover.role.rawValue,
            id: verdict.cover.trimmedID,
            label: verdict.cover.trimmedLabel.map { SelectorText.truncated($0) },
            frame: verdict.cover.frame,
            screen: verdict.screen.map { SelectorText.truncated($0) },
            evidence: verdict.evidence
        )
    }

    var jsonValue: OrderedJSON {
        .object([
            ("role", .string(role)),
            ("id", .optional(id, OrderedJSON.string)),
            ("label", .optional(label, OrderedJSON.string)),
            ("frame", frame.map(\.jsonValue) ?? .null),
            ("screen", .optional(screen, OrderedJSON.string)),
            ("evidence", .string(evidence.rawValue)),
        ])
    }
}

/// A failure with a typed reason; `hint` is a command to run next and never echoes typed text.
public protocol OffsiderFailure: Error {
    var reason: FailureReason { get }
    var failureMessage: String { get }
    var hint: String? { get }
    var candidates: [FailureCandidate] { get }
    var coveredBy: CoverReport? { get }
}

extension OffsiderFailure {
    public var hint: String? { nil }
    public var candidates: [FailureCandidate] { [] }
    public var coveredBy: CoverReport? { nil }
    public var exitCode: OffsiderExitCode { reason.exitCode }
}
