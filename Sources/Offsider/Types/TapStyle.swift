import ArgumentParser
import Foundation
import OffsiderCore

enum TapStyle: String, CaseIterable, ExpressibleByArgument {
    case automatic
    case simulator
    case physical
}

struct TapResolution {
    let point: (x: Double, y: Double)
    let isSwitchLikeControl: Bool
    /// The element tapped and the one the selector matched; nil for a coordinate tap.
    var target: UINode? = nil
    var matched: UINode? = nil
    /// Elements that may draw over the tap point; empty when none do or the check was skipped.
    var coverCandidates: [UINode] = []
}
