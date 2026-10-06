import Foundation
import OffsiderCore

/// `cmd device_state`: the states a device supports and the one it committed, which is a foldable's posture.
enum AndroidDeviceState {
    static let printStates = "cmd device_state print-states"
    static let readState = "cmd device_state state"
    static let resetState = "cmd device_state state reset"

    static func setState(_ state: State) -> String {
        "cmd device_state state \(state.identifier)"
    }

    struct State: Equatable, Sendable {
        let identifier: Int
        let name: String

        var posture: Posture { AndroidDeviceState.posture(named: name) }
    }

    /// `state`'s output: the committed state, plus the base and override while an override is set.
    struct Reading: Equatable, Sendable {
        let committed: State
        let base: State?
        let override: State?
    }

    /// Every `DeviceState{identifier=0, name='CLOSED', ...}` in `print-states`, in order.
    static func parseStates(_ output: String) -> [State] {
        output.split(whereSeparator: \.isNewline).compactMap { state(in: String($0)) }
    }

    /// Nil when `state` printed no committed state.
    static func parseReading(_ output: String) -> Reading? {
        var committed: State?
        var base: State?
        var override: State?
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("Committed state:") {
                committed = state(in: line)
            } else if line.hasPrefix("Base state:") {
                base = state(in: line)
            } else if line.hasPrefix("Override state:") {
                override = state(in: line)
            }
        }
        return committed.map { Reading(committed: $0, base: base, override: override) }
    }

    /// AOSP's names and One UI's (`CLOSE`, `HALF_FOLDED`, `OPEN`); tent, rear display and concurrent states have no posture name.
    static func posture(named name: String) -> Posture {
        switch name.uppercased() {
        case "CLOSED", "CLOSE": return .closed
        case "HALF_OPENED", "HALF_FOLDED": return .halfOpened
        case "OPENED", "OPEN": return .open
        default: return .unknown
        }
    }

    private static func state(in line: String) -> State? {
        guard let start = line.range(of: "DeviceState{"),
              let idRange = line.range(of: "identifier=", range: start.upperBound..<line.endIndex),
              let nameRange = line.range(of: "name='", range: start.upperBound..<line.endIndex),
              let nameEnd = line[nameRange.upperBound...].firstIndex(of: "'") else {
            return nil
        }
        let digits = line[idRange.upperBound...].prefix { $0.isNumber || $0 == "-" }
        guard let identifier = Int(digits) else { return nil }
        return State(identifier: identifier, name: String(line[nameRange.upperBound..<nameEnd]))
    }
}
