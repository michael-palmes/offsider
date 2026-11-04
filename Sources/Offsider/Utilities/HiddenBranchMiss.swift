import Foundation
import OffsiderCore

/// A selector that only a branch Android left out as not visible matches: saying where it is beats "Did you mean", which points elsewhere.
struct HiddenBranchMiss: LocalizedError, UserFacingError, OffsiderFailure {
    let miss: ElementResolutionError
    let selector: String
    let branch: UITreeContext.HiddenBranch
    /// `the navigation bar` or `the status bar`, when one lies over it.
    let bar: String?

    /// `miss` naming the hidden branch the query matches, when `tree` lists one; else `miss` as it was.
    static func wrapping(_ miss: ElementResolutionError, query: AccessibilityQuery, tree: UITree) -> any Error {
        guard case .notFound = miss, let branch = tree.namedHiddenBranches?.first(where: { matches($0, query) }) else { return miss }
        let over = bar(over: branch.frame, in: tree)
        let name = over?.frame.map { $0.y <= (tree.viewport?.y ?? 0) + 1 ? "the status bar" : "the navigation bar" }
        return HiddenBranchMiss(miss: miss, selector: query.selectorDescription, branch: branch, bar: name)
    }

    /// The id or label the helper named it by; never a value, which it does not send.
    static func matches(_ branch: UITreeContext.HiddenBranch, _ query: AccessibilityQuery) -> Bool {
        switch query {
        case .id(let id):
            let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.id == wanted || branch.id?.hasSuffix(":id/" + wanted) == true
        case .label, .labelContains:
            return query.matches(UINode(role: .other, label: branch.label, frame: branch.frame, native: .android(AndroidNativeAttributes())))
        case .value:
            return false
        case .all(let primary, _):
            return matches(branch, primary)
        }
    }

    /// The Android bar over the part of `frame` the screen shows, as a selector tap's cover check finds it.
    static func bar(over frame: UIFrame?, in tree: UITree) -> UINode? {
        guard let frame else { return nil }
        let shown = tree.viewport.flatMap(frame.intersection) ?? frame
        return KnownOverlays.systemBar(at: shown.center, in: tree)
    }

    var userFacingDescription: String {
        let place = branch.frame.map { " at \($0.summary)" } ?? ""
        if let bar {
            let way = bar == "the status bar" ? "down below" : "up above"
            return "\(selector) is under \(bar)\(place), so Android marks it hidden and nothing was sent. Scroll it \(way) the bar, then retry."
        }
        return "\(selector) is on the page\(place), but Android marks it hidden, as it does a view another covers or clips, so nothing was sent. Scroll it into view or close what covers it, then retry."
    }

    var errorDescription: String? { userFacingDescription }
    var reason: FailureReason { miss.reason }
    var failureMessage: String { userFacingDescription }
    var hint: String? { miss.hint }
    var candidates: [FailureCandidate] { miss.candidates }
}
