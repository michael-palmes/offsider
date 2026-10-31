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
    /// How close a near miss came to the selector's text; nil for an element the selector matched.
    public var closeness: SelectorText.Closeness?

    public init(id: String?, label: String?, role: String, frame: UIFrame?, onScreen: Bool?, index: Int? = nil, window: String? = nil, screen: String? = nil, beneath: Bool? = nil, closeness: SelectorText.Closeness? = nil) {
        self.id = id
        self.label = label
        self.role = role
        self.frame = frame
        self.onScreen = onScreen
        self.index = index
        self.window = window
        self.screen = screen
        self.beneath = beneath
        self.closeness = closeness
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
            ("closeness", .optional(closeness?.rawValue, OrderedJSON.string)),
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
    /// The process that draws it, when that is not the app (`evidence` `otherProcess`).
    public let process: String?

    public init(role: String, id: String?, label: String?, frame: UIFrame?, screen: String?, evidence: CoverEvidence, process: String? = nil) {
        self.role = role
        self.id = id
        self.label = label
        self.frame = frame
        self.screen = screen
        self.evidence = evidence
        self.process = process
    }

    public init(_ verdict: CoverVerdict, process: String? = nil) {
        self.init(
            role: verdict.cover.role.rawValue,
            id: verdict.cover.normalizedID,
            label: verdict.cover.normalizedLabel.map { SelectorText.truncated(OutputMasks.current.mask.shownLabel($0, id: verdict.cover.normalizedID)) },
            frame: verdict.cover.frame,
            screen: verdict.screen.map { SelectorText.truncated($0) },
            evidence: verdict.evidence,
            process: process
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
            ("process", .optional(process, OrderedJSON.string)),
        ])
    }
}

/// A saved login a `--where` could have meant: its name, tags and about note, never a username.
public struct FailureUser: Equatable, Sendable {
    public let name: String
    public let tags: [String]
    public let about: String?

    public init(name: String, tags: [String], about: String?) {
        self.name = name
        self.tags = tags
        self.about = about
    }

    public init(_ entry: LoginEntry) {
        self.init(name: entry.name, tags: entry.context.tags.map(\.rawValue), about: entry.context.about)
    }

    var jsonValue: OrderedJSON {
        .object([
            ("name", .string(name)),
            ("tags", .array(tags.map { .string($0) })),
            ("about", .optional(about, OrderedJSON.string)),
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
    var users: [FailureUser] { get }
    /// What to ask the user when only their hands can clear this; `PersonAsk.devicePlaceholder` is filled in when it is reported.
    var ask: String? { get }
}

extension OffsiderFailure {
    public var ask: String? { reason.personAsk }
    public var hint: String? { nil }
    public var candidates: [FailureCandidate] { [] }
    public var coveredBy: CoverReport? { nil }
    public var users: [FailureUser] { [] }
    public var exitCode: OffsiderExitCode { reason.exitCode }
}
