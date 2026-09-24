import Foundation

public enum OffsiderExitCode: Int32, Sendable {
    case success = 0
    case failure = 1
    case doctorWarnings = 3
    case doctorFailures = 4
    case unverified = 5
    case usage = 64
}
