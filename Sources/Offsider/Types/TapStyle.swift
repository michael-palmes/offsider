import ArgumentParser
import Foundation
import OffsiderCore

enum TapStyle: String, CaseIterable, ExpressibleByArgument {
    case automatic
    case simulator
    case physical
}

/// Which of several on-screen matches to take, in tree order, instead of failing as ambiguous.
enum MatchPick: Equatable, Sendable {
    /// 1-based.
    case nth(Int)
    /// The last, which Android draws on top.
    case last
}

/// Chooses among a tree's matches on each read, so an iOS `--topmost` hit-test sees the tree it picks from.
typealias MatchPicker = @MainActor ([UINode]) async -> MatchPick?

struct TapResolution {
    let point: (x: Double, y: Double)
    let isSwitchLikeControl: Bool
    /// The element tapped and the one the selector matched; nil for a coordinate tap.
    var target: UINode? = nil
    var matched: UINode? = nil
    /// Elements that may draw over the tap point; empty when none do or the check was skipped.
    var coverCandidates: [UINode] = []
    /// The pages the tree showed, read only when there were candidates.
    var stack: ScreenStack? = nil
}
