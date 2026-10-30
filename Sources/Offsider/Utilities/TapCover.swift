import Foundation
import OffsiderCore

/// The cover check a selector tap makes before it sends anything: refuse a confident cover, warn on a guess, or let it through.
struct TapCover {
    /// Tap through a confident cover with a warning.
    var allowCovered = false
    /// Refuse a guessed cover too.
    var failIfCovered = false
    /// How to tap anyway, for the refusal's last sentence.
    var override = "pass --allow-covered to tap anyway"

    /// What a cover check needs about one resolved target: the roots and pages it judges, what may draw over the point, and whether a hit-test would tell.
    struct Judging {
        let target: UINode
        let matched: UINode
        let point: UIPoint
        let roots: [UINode]
        let viewport: UIFrame
        let stack: ScreenStack
        let candidates: [UINode]
        let logBoxInset: Double
        /// The app's tree shows the empty host of another process's prompt over the target.
        let promptHost: Bool
        /// Something may draw over the point, so the judge has work to do; else the point is clear.
        let isContested: Bool

        /// The keyboard over the point, which `check` refuses before anything else; nil when it is clear of keys.
        let keyboard: UINode?

        /// Nil for a coordinate tap or a tree without a viewport; `beneath` is what the caller already knows of the target's screen.
        init?(_ resolution: TapResolution, in tree: UITree, beneath known: Bool? = nil) {
            guard let target = resolution.target ?? resolution.matched, let viewport = tree.viewport else {
                return nil
            }
            let android = tree.platform == .android
            keyboard = AccessibilityTargetResolver.keyboardCover(resolution, in: tree)
            let roots = AccessibilityTargetResolver.coverRoots(tree.roots, android: android)
            var candidates = resolution.coverCandidates
            if android {
                candidates.removeAll { AccessibilityTargetResolver.isUnderKeyboard($0, in: tree.roots) }
            }
            let stack = roots.count == tree.roots.count ? resolution.stack ?? ScreenStack.build(roots: roots, viewport: viewport) : ScreenStack.build(roots: roots, viewport: viewport)
            let matched = resolution.matched ?? target
            let beneath = known ?? (stack.isBeneath(target, in: roots) || stack.isBeneath(matched, in: roots))
            let point = UIPoint(x: resolution.point.x, y: resolution.point.y)
            let logBoxInset = KnownOverlays.logBoxTopInset(in: tree)
            if logBoxInset > 0 {
                candidates += TapCover.logBoxToasts(reaching: target, at: point, inset: logBoxInset, roots: roots, viewport: viewport, stack: stack, besides: candidates)
            }
            // Empty containers never cover, but the empty host of another process's prompt is worth a hit-test.
            promptHost = !android && SystemPrompt.hasHost(over: target, in: tree)
            isContested = android || !candidates.isEmpty || beneath || promptHost
            self.target = target
            self.matched = matched
            self.point = point
            self.roots = roots
            self.viewport = viewport
            self.stack = stack
            self.candidates = candidates
            self.logBoxInset = logBoxInset
        }

        /// The process ids a hit-test should count as the app's own: the prompt host's, while one is up.
        var appPIDs: Set<Int> { promptHost ? SystemPrompt.pids(in: roots) : [] }

        /// True only when the simulator's `hit` is the target or inside it.
        func surelyReaches(hit: UINode) -> Bool {
            CoverJudge.surelyReaches(target: target, matched: matched, point: point, roots: roots, viewport: viewport, stack: stack, hit: hit)
        }

        /// What the tap would reach instead, given the simulator's `hit` if one was read; nil when it reaches the target, or nothing contests it and no hit was read.
        func verdict(hit: UINode?) -> CoverVerdict? {
            guard isContested || hit != nil else { return nil }
            return CoverJudge.judge(
                target: target, matched: matched, point: point, candidates: candidates, roots: roots, viewport: viewport, stack: stack, hit: hit,
                logBoxInset: logBoxInset, otherProcessCovers: promptHost
            )
        }
    }

    /// Throws `target_under_keyboard` or `target_covered`, or prints a warning; returns the tap to send, moved to the part of the target that shows when a cover holds its point.
    @MainActor
    @discardableResult
    func check(_ resolution: TapResolution, selector: String, tree: UITree, backend: any DeviceBackend, device: DeviceID) async throws -> TapResolution {
        guard let judging = Judging(resolution, in: tree) else {
            return resolution
        }
        // Before the hit-test, which on a simulator can answer with the field beneath the keyboard.
        if judging.keyboard != nil {
            throw Tap.keyboardCoverError(selector: selector, at: resolution.point, device: device)
        }
        guard judging.isContested else {
            return resolution
        }
        let hitTester = tree.platform == .android ? nil : backend as? any PointHitTesting
        guard let verdict = await Self.verdict(judging, in: tree, hitTester: hitTester, device: device) else {
            return resolution
        }
        if verdict.evidence == .otherProcess, let hitTester, let pid = verdict.cover.iosPID {
            let prompt = await SystemPromptProbe.prompt(of: verdict.cover, pid: pid, in: tree, hitTester: hitTester, device: device)
            try refuse(under: prompt, verdict: verdict, selector: selector, at: judging.point, viewport: judging.viewport, device: device)
            return resolution
        }
        if AccessibilityTargetResolver.isUnderKeyboard(verdict.cover, in: judging.roots) {
            throw Tap.keyboardCoverError(selector: selector, at: resolution.point, device: device)
        }
        if verdict.isConfident, !allowCovered, verdict.evidence == .hitTest,
           let moved = await clearPart(of: resolution, beside: verdict.cover, in: tree, backend: backend, device: device) {
            Console.current.notice(.note(
                "\(selector) shows beside \(Self.describe(verdict)); tapping its visible part",
                agent: "\(selector) at \(VerifyOutput.pointDescription(x: judging.point.x, y: judging.point.y)) is under \(Self.describe(verdict)); tapping the part that shows at \(VerifyOutput.pointDescription(x: moved.point.x, y: moved.point.y))."
            ))
            return moved
        }
        try act(on: verdict, selector: selector, at: judging.point, device: device)
        return resolution
    }

    /// The front reading's verdict when the shared judgement already read this point on this tree, else the judge's own, with a hit-test on a simulator.
    @MainActor
    static func verdict(_ judging: Judging, in tree: UITree, hitTester: (any PointHitTesting)?, device: DeviceID) async -> CoverVerdict? {
        if let front = tree.front, judging.target.isSameElement(as: judging.matched),
           let index = ScreenStack.index(of: judging.matched, in: tree.roots), let judged = front.judged[index], judged.point == judging.point {
            return judged.verdict
        }
        var hit: UINode?
        if let hitTester {
            hit = try? await hitTester.hitTest(at: judging.point, on: device, appPIDs: judging.appPIDs)
        }
        return judging.verdict(hit: hit)
    }

    /// The tap moved to the middle of a part of the target that `cover` leaves showing, at least 8 pt across, where the simulator's hit-test finds the target itself; full-width parts first, two tries at most. Nil without a hit-test, which alone proves the part is not under something the tree leaves out.
    @MainActor
    private func clearPart(of resolution: TapResolution, beside cover: UINode, in tree: UITree, backend: any DeviceBackend, device: DeviceID) async -> TapResolution? {
        guard tree.platform == .ios, let coverFrame = cover.frame, let reader = FrontJudge.PointReader(backend: backend, device: device) else { return nil }
        for moved in Self.clearParts(of: resolution, beside: coverFrame, in: tree).prefix(2) {
            guard let judging = Judging(moved, in: tree), judging.keyboard == nil,
                  let hit = await reader.read(at: judging.point),
                  judging.surelyReaches(hit: hit) else { continue }
            return moved
        }
        return nil
    }

    /// The tap moved to the middle of each part of the target that a cover at `coverFrame` leaves showing, best first; empty when none is 8 pt across.
    static func clearParts(of resolution: TapResolution, beside coverFrame: UIFrame, in tree: UITree) -> [TapResolution] {
        guard let target = resolution.target, let frame = target.frame, let viewport = tree.viewport,
              let visible = AccessibilityTargetResolver.visibleRegion(of: target, frame: frame, viewport: viewport, roots: tree.roots),
              let overlap = visible.intersection(coverFrame) else { return [] }
        return parts(of: visible, outside: overlap, minimum: frame).map { part in
            AccessibilityTargetResolver.resolution(of: resolution, at: part.center, roots: tree.roots, viewport: viewport)
        }
    }

    /// The bands of `visible` above, below, left and right of `overlap` at least 8 pt across (less for a smaller target): full-width bands first, then the larger.
    static func parts(of visible: UIFrame, outside overlap: UIFrame, minimum frame: UIFrame) -> [UIFrame] {
        let extent = AccessibilityTargetResolver.minimumVisibleExtent
        let right = visible.x + visible.width, bottom = visible.y + visible.height
        let overlapRight = overlap.x + overlap.width, overlapBottom = overlap.y + overlap.height
        let across = [
            UIFrame(x: visible.x, y: visible.y, width: visible.width, height: overlap.y - visible.y),
            UIFrame(x: visible.x, y: overlapBottom, width: visible.width, height: bottom - overlapBottom),
        ]
        let beside = [
            UIFrame(x: visible.x, y: visible.y, width: overlap.x - visible.x, height: visible.height),
            UIFrame(x: overlapRight, y: visible.y, width: right - overlapRight, height: visible.height),
        ]
        let wide = { (part: UIFrame) in part.width >= min(extent, frame.width) && part.height >= min(extent, frame.height) }
        let larger = { (a: UIFrame, b: UIFrame) in a.width * a.height > b.width * b.height }
        return across.filter(wide).sorted(by: larger) + beside.filter(wide).sorted(by: larger)
    }

    /// Refuses a confident cover, or a guessed one with `--fail-if-covered`, and warns of the rest.
    private func act(on verdict: CoverVerdict, selector: String, at point: UIPoint, device: DeviceID) throws {
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        let cover = Self.describe(verdict)
        if verdict.isConfident, allowCovered {
            Console.current.notice(.warning(
                "\(selector) is covered by \(cover); tapping anyway (--allow-covered)",
                agent: "\(selector) at \(pointText) is covered by \(cover) (\(Self.evidence(verdict.evidence))); tapping anyway because of --allow-covered."
            ))
            return
        }
        if verdict.isConfident {
            throw CLIError(
                errorDescription: "\(selector) at \(pointText) is covered by \(cover) (\(Self.evidence(verdict.evidence))), so the tap would land on it. Nothing was sent. Close what covers it or wait for it to go (--wait-timeout), or \(override).",
                reason: .targetCovered,
                hint: "offsider describe-ui --device \(device.rawValue) --summary",
                coveredBy: CoverReport(verdict)
            )
        }
        let message = "\(selector) at \(pointText) may be covered by \(cover); the tap may land on it."
        if failIfCovered {
            throw CLIError(errorDescription: message, reason: .targetCovered, hint: "offsider describe-ui --device \(device.rawValue) --summary", coveredBy: CoverReport(verdict))
        }
        Console.current.notice(.warning(
            "\(selector) may be covered by \(cover); the tap may land on it",
            agent: "\(message) Pass --fail-if-covered to stop instead."
        ))
    }

    /// A prompt another process draws over the app takes the tap, so it refuses unless `--allow-covered`.
    private func refuse(under prompt: SystemPrompt, verdict: CoverVerdict, selector: String, at point: UIPoint, viewport: UIFrame, device: DeviceID) throws {
        if allowCovered {
            let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
            Console.current.notice(.warning(
                "\(selector) is under \(prompt.summary); tapping anyway (--allow-covered)",
                agent: "\(selector) at \(pointText) is under \(prompt.summary); tapping anyway because of --allow-covered."
            ))
            return
        }
        throw CLIError(
            errorDescription: Self.promptRefusal(selector: selector, at: point, prompt: prompt, hit: verdict.cover, viewport: viewport, device: device, override: override),
            reason: .targetCovered,
            hint: "offsider screenshot --device \(device.rawValue)",
            coveredBy: CoverReport(CoverVerdict(cover: verdict.cover, evidence: .otherProcess, isConfident: true, screen: prompt.title), process: prompt.process)
        )
    }

    /// Says what the tap would reach on the prompt: its backdrop, which a tap dismisses, or one of its controls.
    static func promptRefusal(selector: String, at point: UIPoint, prompt: SystemPrompt, hit: UINode, viewport: UIFrame, device: DeviceID, override: String) -> String {
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        let lead = "\(selector) at \(pointText) is under \(prompt.summary)"
        let answer = "Answer the prompt (its buttons are not in describe-ui, so take a screenshot to find them)"
        let isBackdrop = !hit.isActionable && hit.normalizedLabel == nil && hit.frame.map { AccessibilityTargetResolver.isBackdrop($0, in: viewport) } == true
        guard isBackdrop else {
            let control = describe(CoverVerdict(cover: hit, evidence: .otherProcess, isConfident: true))
            return "\(lead), so the tap would land on its \(control). Nothing was sent. \(answer), then retry; or \(override)."
        }
        let dismiss = "offsider tap -x \(VerifyOutput.number(point.x)) -y \(VerifyOutput.number(point.y)) --device \(device.rawValue)"
        return "\(lead), so the tap would land on its backdrop and only dismiss it. Nothing was sent. \(answer) or dismiss it with a tap on its backdrop (`\(dismiss)`), then retry; or \(override)."
    }

    /// Toasts whose touch area, grown by `inset`, holds the point or reaches the target, beyond those the resolver found; never one holding the target or beneath a page.
    static func logBoxToasts(reaching target: UINode, at point: UIPoint, inset: Double, roots: [UINode], viewport: UIFrame, stack: ScreenStack, besides found: [UINode]) -> [UINode] {
        roots.flatMap { $0.flattened() }.filter { node in
            guard let area = KnownOverlays.logBoxTouchArea(of: node, in: viewport, inset: inset),
                  area.contains(point) || CoverJudge.reaches(area, target.frame),
                  !found.contains(where: { $0.isSameElement(as: node) }),
                  !node.flattened().contains(where: { $0.isSameElement(as: target) }) else { return false }
            return !stack.isBeneath(node, in: roots)
        }
    }

    /// `button "Buy" (197, 793) 189x45 on stack-test-full-page-1`.
    static func describe(_ verdict: CoverVerdict) -> String {
        var parts = [verdict.cover.role.rawValue]
        if let name = MatchSummary.shownLabel(of: verdict.cover) ?? verdict.cover.normalizedID {
            parts.append(TerminalText.quoted(SelectorText.truncated(name)))
        }
        if let frame = verdict.cover.frame {
            parts.append(frame.summary)
        }
        if let screen = verdict.screen, screen != verdict.cover.normalizedID {
            parts.append("on \(TerminalText.field(SelectorText.truncated(screen)))")
        }
        return parts.joined(separator: " ")
    }

    static func evidence(_ evidence: CoverEvidence) -> String {
        switch evidence {
        case .hitTest: return "a hit-test at the point found it"
        case .drawingOrder: return "Android draws it on top there"
        case .treeOrder: return "by tree order"
        case .logBoxTouchArea: return "LogBox's toast takes touches beyond its frame there"
        case .otherProcess: return "a hit-test at the point found another process's view"
        }
    }

    /// A confident or refused cover, which a wait may outlast.
    static func isRefusal(_ error: any Error) -> Bool {
        (error as? CLIError)?.reason == .targetCovered
    }

    /// How long a keyboard over the target is read again, so one caught as it appears or changes mode does not refuse.
    static let keyboardSettle: TimeInterval = 1

    static func isKeyboardRefusal(_ error: any Error) -> Bool {
        (error as? CLIError)?.reason == .targetUnderKeyboard
    }
}
