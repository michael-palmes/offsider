import Foundation

public enum CheckStatus: String, Codable, Sendable, CaseIterable {
    case pass
    case skip
    case warn
    case fail

    public var severity: Int {
        switch self {
        case .pass, .skip: return 0
        case .warn: return 1
        case .fail: return 2
        }
    }

    /// The worst status in the sequence; `skip` counts as `pass` and an empty sequence passes.
    public static func aggregate<S: Sequence>(_ statuses: S) -> CheckStatus where S.Element == CheckStatus {
        let worst = statuses.map(\.severity).max() ?? 0
        switch worst {
        case 2: return .fail
        case 1: return .warn
        default: return .pass
        }
    }
}
