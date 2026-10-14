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
