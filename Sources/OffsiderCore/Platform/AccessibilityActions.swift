import Foundation

/// What a range action did to a slider or progress control.
public enum RangeActionOutcome: Equatable, Sendable {
    /// The device took the action; `reachable` is the 0...1 position the control can show (its nearest step).
    case performed(reachable: Double)
    /// The node does not offer the action or refused it; the caller falls back to a gesture.
    case unsupported(reason: String)
    /// The node changed or left the screen since the tree was read; resolve it again.
    case stale
}

/// Optional capability: accessibility actions on a node from the backend's latest tree.
@MainActor
public protocol AccessibilityActionPerforming: DeviceBackend {
    /// Sets `node`, as matched in the backend's latest tree, to `fraction` (0...1) of its own range.
    func setRangeValue(_ fraction: Double, of node: UINode, on id: DeviceID) async throws -> RangeActionOutcome
}

/// Optional capability: a cheap signal that the screen may have changed since the latest tree read.
@MainActor
public protocol AccessibilityChangeWaiting: DeviceBackend {
    /// True as soon as a relevant accessibility event follows the latest tree read; false after `timeout`.
    func waitForAccessibilityChange(on id: DeviceID, timeout: Duration) async throws -> Bool
}
