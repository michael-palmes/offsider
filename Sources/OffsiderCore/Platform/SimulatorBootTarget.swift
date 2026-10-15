import Foundation

/// A simulator `boot` can start: picked by UDID, or by a name only one simulator has.
public struct SimulatorBootCandidate: Equatable, Sendable {
    public let udid: String
    public let name: String
    public let state: String
    public let osVersion: String?

    public init(udid: String, name: String, state: String, osVersion: String?) {
        self.udid = udid
        self.name = name
        self.state = state
        self.osVersion = osVersion
    }
}

public enum SimulatorBootTarget {
    public enum Match: Equatable, Sendable {
        case one(SimulatorBootCandidate)
        case none
        /// Several simulators share the name; a booted one is never picked for the user.
        case several([SimulatorBootCandidate])
    }

    /// A UDID matches its simulator; a name matches exactly, then ignoring case.
    public static func match(_ target: String, among simulators: [SimulatorBootCandidate]) -> Match {
        let wanted = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: wanted) {
            return simulators.first { $0.udid.uppercased() == uuid.uuidString }.map(Match.one) ?? .none
        }
        var named = simulators.filter { $0.name == wanted }
        if named.isEmpty {
            named = simulators.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        switch named.count {
        case 0: return .none
        case 1: return .one(named[0])
        default: return .several(named)
        }
    }

    /// The usage error for a name several simulators share, listing each UDID to pass instead.
    public static func ambiguity(_ target: String, _ simulators: [SimulatorBootCandidate]) -> String {
        let rows = simulators.map { "  \($0.udid)  \($0.osVersion ?? "-")  \($0.state)" }
        return "\(simulators.count) simulators are named \(target). Boot one by its UDID:\n" + rows.joined(separator: "\n")
    }
}

/// `boot --json` for a simulator: its UDID and name, and whether it was already booted.
public struct SimulatorBootReport: Equatable, Sendable {
    public static let schemaVersion = 1

    public let udid: String
    public let name: String
    public let alreadyRunning: Bool

    public init(udid: String, name: String, alreadyRunning: Bool) {
        self.udid = udid
        self.name = name
        self.alreadyRunning = alreadyRunning
    }

    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(Self.schemaVersion)),
            ("ok", .bool(true)),
            ("platform", .string("ios")),
            ("name", .string(name)),
            ("udid", .string(udid)),
            ("alreadyRunning", .bool(alreadyRunning)),
            ("exitCode", .integer(0)),
        ]).rendered(compact: true)
    }
}

/// What `boot` does for a simulator in each state: a second `boot` while one is under way waits for it instead of starting another.
public enum SimulatorBootStep: Equatable, Sendable {
    case alreadyBooted
    case boot
    case waitForBoot

    public static func step(for state: String) -> SimulatorBootStep {
        switch state.lowercased() {
        case "booted": return .alreadyBooted
        case "booting": return .waitForBoot
        default: return .boot
        }
    }
}

/// Waits for work that must outlive the wait, such as a simulator boot a rerun picks up again.
public enum DetachedWait {
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, any Error>?

        init(_ continuation: CheckedContinuation<Bool, any Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<Bool, any Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, any Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }

    /// True when `work` finished within `timeout`; false when the time ran out first, leaving `work` running, never cancelled.
    public static func finishes(within timeout: Duration, _ work: @escaping @Sendable () async throws -> Void) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = Outcome(continuation)
            let timer = Task.detached {
                try? await Task.sleep(for: timeout)
                outcome.resume(.success(false))
            }
            Task.detached {
                do {
                    try await work()
                    outcome.resume(.success(true))
                } catch {
                    outcome.resume(.failure(error))
                }
                timer.cancel()
            }
        }
    }
}
