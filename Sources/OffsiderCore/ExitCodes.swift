import Foundation

public enum OffsiderExitCode: Int32, CaseIterable, Sendable {
    case success = 0
    case failure = 1
    case selectorNotFound = 2
    case doctorWarnings = 3
    case doctorFailures = 4
    case unverified = 5
    case ambiguousSelector = 6
    case deviceUnavailable = 7
    case deviceBusy = 8
    case toolMissing = 9
    case usage = 64
}
