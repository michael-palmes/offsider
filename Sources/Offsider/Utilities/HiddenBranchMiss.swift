import Foundation
import OffsiderCore

/// A selector that only a branch Android left out as not visible matches: saying where it is beats "Did you mean", which points elsewhere.
struct HiddenBranchMiss: LocalizedError, UserFacingError, OffsiderFailure {
    let miss: ElementResolutionError
    let selector: String
    let branch: UITreeContext.HiddenBranch
    let underBar: Bool

    /// `miss` naming the hidden branch the query matches, when `tree` lists one; else `miss` as it was.
    static func wrapping(_ miss: ElementResolutionError, query: AccessibilityQuery, tree: UITree) -> any Error {
        guard case .notFound = miss, let branch = tree.namedHiddenBranches?.first(where: { matches($0, query) }) else { return miss }
        return HiddenBranchMiss(miss: miss, selector: query.selectorDescription, branch: branch, underBar: underNavigationBar(branch.frame, in: tree))
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

    /// A listed system window along the app's bottom edge, at least 90 % as wide as the app's and at most a quarter as tall, over part of `frame`.
    static func underNavigationBar(_ frame: UIFrame?, in tree: UITree) -> Bool {
        guard let frame, let windows = tree.windows,
              let app = (windows.first { $0.kind == "application" && $0.active } ?? windows.first { $0.kind == "application" })?.bounds,
              app.width > 0, app.height > 0 else { return false }
        return windows.contains { window in
            guard window.kind == "system", let bar = window.bounds, bar.width >= 0.9 * app.width, bar.height > 0, bar.height <= app.height / 4,
                  bar.y > app.y + 1, bar.y + bar.height >= app.y + app.height - 1 else { return false }
            return frame.intersection(bar) != nil
        }
    }

    var userFacingDescription: String {
        let place = branch.frame.map { " at \($0.summary)" } ?? ""
        if underBar {
            return "\(selector) is under the navigation bar\(place), so Android marks it hidden and nothing was sent. Scroll it up above the bar, then retry."
        }
        return "\(selector) is on the page\(place), but Android marks it hidden, as it does a view another covers or clips, so nothing was sent. Scroll it into view or close what covers it, then retry."
    }

    var errorDescription: String? { userFacingDescription }
    var reason: FailureReason { miss.reason }
    var failureMessage: String { userFacingDescription }
    var hint: String? { miss.hint }
    var candidates: [FailureCandidate] { miss.candidates }
}
