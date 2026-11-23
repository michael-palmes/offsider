import Foundation
import OffsiderCore

/// A selector that only a branch Android left out as not visible matches: saying where it is beats "Did you mean", which points elsewhere.
struct HiddenBranchMiss: LocalizedError, UserFacingError, OffsiderFailure {
    let miss: ElementResolutionError
    let selector: String
    let branch: UITreeContext.HiddenBranch
    /// `the navigation bar` or `the status bar`, when one lies over it.
    let bar: String?
    /// Wholly outside the screen, as on a sheet parked out of view.
    var offScreen = false
    /// Wholly inside the screen, so nothing clips it and a scroll would not help.
    var onScreen = false

    /// `miss` naming the hidden branch the query matches, when `tree` lists one; else `miss` as it was.
    static func wrapping(_ miss: ElementResolutionError, query: AccessibilityQuery, tree: UITree) -> any Error {
        guard case .notFound = miss, let found = found(miss, query: query, tree: tree) else { return miss }
        return found
    }

    /// For a `wait` or `assert` that ends with nothing matching: where Android hid the element, in place of the nearest other one.
    static func nearMiss(query: AccessibilityQuery, tree: UITree) -> WaitNearMiss? {
        let primary = if case .all(let primary, _) = query { primary } else { query }
        guard AccessibilityTargetResolver.candidates(roots: tree.roots, query: primary, elementType: nil).matches.isEmpty else { return nil }
        return found(.notFound(kind: query.kind, value: query.rawValue), query: query, tree: tree).map { found in
            WaitNearMiss(summary: "\(found.situation(subject: found.selector)): \(found.fix.prefix(1).lowercased())\(found.fix.dropFirst())", candidates: [])
        }
    }

    private static func found(_ miss: ElementResolutionError, query: AccessibilityQuery, tree: UITree) -> HiddenBranchMiss? {
        guard let branch = tree.namedHiddenBranches?.first(where: { matches($0, query) }) else { return nil }
        let over = bar(over: branch.frame, in: tree)
        let name = over?.frame.map { $0.y <= (tree.viewport?.y ?? 0) + 1 ? "the status bar" : "the navigation bar" }
        let offScreen = branch.frame.map { frame in tree.viewport.map { frame.intersection($0) == nil } ?? false } ?? false
        let onScreen = branch.frame.map { frame in tree.viewport.map { $0.encloses(frame, tolerance: 1) } ?? false } ?? false
        return HiddenBranchMiss(miss: miss, selector: query.selectorDescription, branch: branch, bar: name, offScreen: offScreen, onScreen: onScreen)
    }

    /// The id or label the helper named it by; never a value, which it does not send.
    static func matches(_ branch: UITreeContext.HiddenBranch, _ query: AccessibilityQuery) -> Bool {
        switch query {
        case .id(let id):
            let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.id == wanted || branch.id?.hasSuffix(":id/" + wanted) == true
        case .label, .labelContains:
            if let label = branch.label, OutputMasks.current.mask.hidesLabel(label, id: branch.id) { return false }
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

    /// Where the element is, with `subject` naming it: `it is under the navigation bar at (0, 870) 412x56, so Android marks it hidden`.
    func situation(subject: String) -> String {
        let place = branch.frame.map { " at \($0.summary)" } ?? ""
        if let bar { return "\(subject) is under \(bar)\(place), so Android marks it hidden" }
        if offScreen { return "Android lists \(subject) as hidden\(place), off the screen, as on a sheet parked out of view" }
        if onScreen { return "Android lists \(subject) as hidden\(place), on screen but under another view or window, such as a sheet" }
        return "Android lists \(subject) as hidden\(place), as it does a view another covers or clips"
    }

    var fix: String {
        if let bar { return "Scroll it \(bar == "the status bar" ? "down below" : "up above") the bar" }
        if offScreen { return "Open what holds it or scroll it into view" }
        if onScreen { return "Close what covers it" }
        return "Scroll it into view or close what covers it"
    }

    var userFacingDescription: String {
        "No accessibility element matched \(selector) on screen: \(situation(subject: "it")). Nothing was sent. \(fix), then retry."
    }

    var errorDescription: String? { userFacingDescription }
    var reason: FailureReason { miss.reason }
    var failureMessage: String { userFacingDescription }
    var hint: String? { miss.hint }
    var candidates: [FailureCandidate] { miss.candidates }
}
