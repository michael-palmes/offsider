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
    /// The flag that turns a guessed cover's warning into a refusal; nil when the command has none.
    var stopFlag: String? = "--fail-if-covered"
    /// Nothing will be sent, so notes say what the tap would do.
    var dryRun = false
    /// `tap`, or `drag` for a slider, as the messages name it.
    var gesture = "tap"
    /// A target a cover leaves part of on show is tapped there; a slider's drag must start where its thumb is.
    var movesToVisiblePart = true
    /// Refuse a target that says it is disabled, as the tap would do nothing.
    var refusesDisabled = true
    /// Tap a disabled target with a warning.
    var allowDisabled = false
    /// How to tap a disabled target anyway, for the refusal's last sentence; nil when there is no way.
    var disabledOverride: String? = "pass --allow-disabled to tap anyway"
    /// The selector, for the `wait` a disabled target's refusal offers.
    var query: AccessibilityQuery?
    /// `tapping` or `dragging`.
    private var gerund: String { gesture == "drag" ? "dragging" : "tapping" }
    /// What this check has said already, as a verified tap judges each read and a note need not repeat.
    let notices = NoticeLog()

    /// Each notice once.
    final class NoticeLog {
        private var shown: Set<Notice> = []

        func say(_ notice: Notice) {
            if shown.insert(notice).inserted { Console.current.notice(notice) }
        }
    }

    /// What every cover check on one tree shares, read once: its index, the roots and pages a check judges, LogBox's inset and where the keyboard takes touches.
    struct Shared {
        let tree: UITree
        /// Over `tree.roots`.
        let index: TreeIndex
        /// Over the roots a check judges: on Android the keyboard's root leaves them.
        let ground: CoverGround
        let logBoxInset: Double
        let keyboardTouchAreas: [UIFrame]?
        /// Empty hosts of other processes' prompts.
        let promptHosts: [(index: Int, window: UINode)]

        /// Nil for a tree without a viewport; `index` and `stack`, when given, are already read over `tree.roots`.
        init?(_ tree: UITree, index: TreeIndex? = nil, stack: ScreenStack? = nil) {
            guard let viewport = tree.viewport else { return nil }
            let index = index ?? TreeIndex(roots: tree.roots)
            let roots = AccessibilityTargetResolver.coverRoots(tree.roots, android: tree.platform == .android)
            if roots.count == tree.roots.count {
                ground = CoverGround(tree: index, viewport: viewport, stack: stack ?? ScreenStack.build(index, viewport: viewport))
            } else {
                let judged = TreeIndex(roots: roots)
                ground = CoverGround(tree: judged, viewport: viewport, stack: ScreenStack.build(judged, viewport: viewport))
            }
            self.tree = tree
            self.index = index
            logBoxInset = KnownOverlays.logBoxTopInset(in: tree)
            keyboardTouchAreas = AccessibilityTargetResolver.keyboardTouchAreas(in: tree)
            promptHosts = SystemPrompt.hosts(in: tree)
        }
    }

    /// What a cover check needs about one resolved target: the roots and pages it judges, what may draw over the point, and whether a hit-test would tell.
    struct Judging {
        let target: UINode
        let matched: UINode
        let point: UIPoint
        let ground: CoverGround
        let candidates: [UINode]
        let logBoxInset: Double
        /// The app's tree shows the empty host of another process's prompt over the target.
        let promptHost: Bool
        /// Something may draw over the point, so the judge has work to do; else the point is clear.
        let isContested: Bool

        /// The keyboard over the point, which `check` refuses before anything else; nil when it is clear of keys.
        let keyboard: UINode?
        /// The tap judged: the one asked for, or moved to the part of the target an Android system bar leaves showing.
        let aimed: TapResolution
        /// The Android system bar the asked point fell in, when the tap moved beside it.
        let movedBeside: UINode?
        /// The Android system bar holding the point, with too little of the target beside it to move to.
        let systemBar: UINode?

        var roots: [UINode] { ground.roots }
        var viewport: UIFrame { ground.viewport }
        var stack: ScreenStack { ground.stack }

        /// Nil for a coordinate tap or a tree without a viewport; `beneath` is what the caller already knows of the target's screen.
        init?(_ asked: TapResolution, in tree: UITree, beneath known: Bool? = nil, movingBesideBars: Bool = true) {
            guard asked.target ?? asked.matched != nil, let shared = Shared(tree, stack: asked.stack) else {
                return nil
            }
            self.init(asked, on: shared, beneath: known, movingBesideBars: movingBesideBars)
        }

        /// `init(_:in:beneath:movingBesideBars:)` on a tree already read for many checks.
        init?(_ asked: TapResolution, on shared: Shared, beneath known: Bool? = nil, movingBesideBars: Bool = true) {
            let tree = shared.tree, ground = shared.ground
            var resolution = asked
            var movedBeside: UINode?
            var systemBar: UINode?
            if let bar = KnownOverlays.systemBar(at: UIPoint(x: asked.point.x, y: asked.point.y), in: tree), let barFrame = bar.frame {
                var named = asked
                named.target = asked.target ?? asked.matched
                let clear = TapCover.clearParts(of: named, beside: barFrame, in: tree).first { part in
                    KnownOverlays.systemBar(at: UIPoint(x: part.point.x, y: part.point.y), in: tree) == nil
                }
                if movingBesideBars, let clear {
                    resolution = clear
                    movedBeside = bar
                } else {
                    systemBar = bar
                }
            }
            guard let target = resolution.target ?? resolution.matched else {
                return nil
            }
            aimed = resolution
            self.movedBeside = movedBeside
            self.systemBar = systemBar
            let android = tree.platform == .android
            keyboard = AccessibilityTargetResolver.keyboardCover(resolution, in: tree, index: shared.index, touchAreas: shared.keyboardTouchAreas)
            var candidates = resolution.coverCandidates
            if android {
                candidates.removeAll(where: shared.index.isUnderKeyboard)
            }
            let matched = resolution.matched ?? target
            let beneath = known ?? (ground.stack.isBeneath(target, in: ground.tree) || ground.stack.isBeneath(matched, in: ground.tree))
            let point = UIPoint(x: resolution.point.x, y: resolution.point.y)
            if shared.logBoxInset > 0 {
                candidates += TapCover.logBoxToasts(reaching: target, at: point, inset: shared.logBoxInset, on: ground, besides: candidates)
            }
            // Empty containers never cover, but the empty host of another process's prompt is worth a hit-test.
            promptHost = !android && SystemPrompt.hasHost(over: target, in: tree, hosts: shared.promptHosts)
            let takenByDevMenu = ground.devMenuButtons.contains { button in
                button.frame.map { KnownOverlays.devMenuButton(at: $0, takes: point) } == true
            }
            isContested = android || systemBar != nil || !candidates.isEmpty || beneath || promptHost || takenByDevMenu
            self.target = target
            self.matched = matched
            self.point = point
            self.ground = ground
            self.candidates = candidates
            logBoxInset = shared.logBoxInset
        }

        /// The process ids a hit-test should count as the app's own: the prompt host's, while one is up.
        var appPIDs: Set<Int> { promptHost ? SystemPrompt.pids(in: roots) : [] }

        /// True only when the simulator's `hit` is the target or inside it.
        func surelyReaches(hit: UINode) -> Bool {
            CoverJudge.surelyReaches(target: target, matched: matched, point: point, on: ground, hit: hit)
        }

        /// `surelyReaches`, but never a control inside the target: moved beside a cover, a tap must not press something nobody named. Text inside it still counts.
        func reachesPart(hit: UINode) -> Bool {
            guard surelyReaches(hit: hit) else { return false }
            guard hit.isActionable else { return true }
            var bareTarget = target, bareMatched = matched
            bareTarget.children = []
            bareMatched.children = []
            return CoverJudge.surelyReaches(target: bareTarget, matched: bareMatched, point: point, on: ground, hit: hit)
        }

        /// A guess that another scroll view's content lies over a target the hit-test found counts only if that content shows: a read at its own point that finds something else puts it beneath what is drawn there. A footer outside any scroll view stays guessed, as a hit-test can answer through one.
        @MainActor
        func isHiddenAtItsOwnPoint(_ cover: UINode, hitTester: any PointHitTesting, device: DeviceID) async -> Bool {
            guard let index = ground.tree.firstIndex(of: cover),
                  ground.tree.chain(to: index).dropLast().contains(where: { [.scrollView, .list].contains($0.role) }),
                  let centre = cover.frame?.center, viewport.contains(centre),
                  let hit = try? await hitTester.hitTest(at: centre, on: device, appPIDs: appPIDs) else { return false }
            return CoverJudge.judge(target: cover, matched: cover, point: centre, candidates: [], on: ground, hit: hit) != nil
        }

        /// What the tap would reach instead, given the simulator's `hit` if one was read; nil when it reaches the target, or nothing contests it and no hit was read.
        func verdict(hit: UINode?) -> CoverVerdict? {
            if let systemBar {
                return CoverVerdict(cover: systemBar, evidence: .systemBar, isConfident: true)
            }
            guard isContested || hit != nil else { return nil }
            return CoverJudge.judge(
                target: target, matched: matched, point: point, candidates: candidates, on: ground, hit: hit,
                logBoxInset: logBoxInset, otherProcessCovers: promptHost
            )
        }
    }

    /// Throws `target_under_keyboard`, `target_covered` or `target_disabled`, or prints a warning; returns the tap to send, moved to the part of the target that shows when a cover holds its point.
    @MainActor
    @discardableResult
    func check(_ resolution: TapResolution, selector: String, tree: UITree, backend: any DeviceBackend, device: DeviceID) async throws -> TapResolution {
        let checked = try await checkCover(resolution, selector: selector, tree: tree, backend: backend, device: device)
        try checkEnabled(checked, selector: selector, tree: tree, device: device)
        return checked
    }

    /// Refuses, or with `allowDisabled` warns, when the control the tap reaches says it is disabled; a control that does not say is tapped.
    @MainActor
    private func checkEnabled(_ resolution: TapResolution, selector: String, tree: UITree, device: DeviceID) throws {
        guard refusesDisabled, let target = resolution.target ?? resolution.matched,
              let control = AccessibilityTargetResolver.disabledControl(reachedBy: target, in: tree.roots) else { return }
        let subject = control.isSameElement(as: target) ? "\(selector) is disabled" : "\(selector) is inside a disabled \(Self.describe(CoverVerdict(cover: control, evidence: .treeOrder, isConfident: true)))"
        if allowDisabled {
            let tapping = dryRun ? "would tap" : "tapping"
            notices.say(.warning("\(subject); \(tapping) anyway (--allow-disabled)", agent: "\(subject); \(tapping) anyway because of --allow-disabled."))
            return
        }
        let wait = Self.waitForEnabled(query?.shellArguments ?? selector, device: device)
        let anyway = disabledOverride.map { ", or \($0)" } ?? ""
        throw CLIError(
            errorDescription: "\(subject), so the \(gesture) would do nothing. Nothing was sent. Wait for it to be enabled (`\(wait)`)\(anyway).",
            reason: .targetDisabled,
            hint: wait,
            candidates: tree.viewport.map { [MatchSummary(control, viewport: $0).failureCandidate] } ?? []
        )
    }

    /// `offsider wait --id save --enabled --timeout 10 --device <id>`.
    @MainActor
    static func waitForEnabled(_ selector: String, device: DeviceID) -> String {
        "offsider wait \(selector) --enabled --timeout 10\(CommandScope.current.appArgument(device: device.rawValue)) --device \(device.rawValue)"
    }

    @MainActor
    private func checkCover(_ asked: TapResolution, selector: String, tree: UITree, backend: any DeviceBackend, device: DeviceID) async throws -> TapResolution {
        guard let judging = Judging(asked, in: tree, movingBesideBars: movesToVisiblePart && !allowCovered) else {
            return asked
        }
        let resolution = judging.aimed
        if let bar = judging.movedBeside {
            let tapping = dryRun ? "would tap" : "tapping"
            let barName = Self.describe(CoverVerdict(cover: bar, evidence: .systemBar, isConfident: true))
            notices.say(.note(
                "\(selector) is partly under \(barName); \(tapping) the part that shows",
                agent: "\(selector) at \(VerifyOutput.pointDescription(x: asked.point.x, y: asked.point.y)) is under \(barName); \(tapping) the part that shows at \(VerifyOutput.pointDescription(x: resolution.point.x, y: resolution.point.y))."
            ))
        }
        // Before the hit-test, which on a simulator can answer with the field beneath the keyboard.
        if judging.keyboard != nil {
            throw Tap.keyboardCoverError(selector: selector, at: resolution.point, device: device, appArgument: CommandScope.current.appArgument(device: device.rawValue), gesture: gesture)
        }
        // Nothing listed overlaps the point, though a view the tree leaves unnamed may lie over it: asked to be sure, the simulator's hit-test settles that.
        guard judging.isContested || failIfCovered else {
            return resolution
        }
        let hitTester = tree.platform == .android ? nil : backend as? any PointHitTesting
        guard let verdict = try await Self.verdict(judging, in: tree, hitTester: hitTester, device: device, sure: failIfCovered) else {
            return resolution
        }
        if verdict.evidence == .otherProcess, let hitTester, let pid = verdict.cover.iosPID {
            let prompt = await SystemPromptProbe.prompt(of: verdict.cover, pid: pid, in: tree, hitTester: hitTester, device: device)
            try refuse(under: prompt, verdict: verdict, selector: selector, at: judging.point, viewport: judging.viewport, device: device)
            return resolution
        }
        if AccessibilityTargetResolver.isUnderKeyboard(verdict.cover, in: judging.roots) {
            throw Tap.keyboardCoverError(selector: selector, at: resolution.point, device: device, appArgument: CommandScope.current.appArgument(device: device.rawValue), gesture: gesture)
        }
        if movesToVisiblePart, verdict.leavesPartShowing, !allowCovered, tree.platform == .ios, let coverFrame = verdict.touchFrame,
           let reader = FrontJudge.PointReader(backend: backend, device: device),
           let moved = await Self.reachablePart(of: resolution, beside: coverFrame, in: tree, reader: reader) {
            let tapping = dryRun ? "would tap" : "tapping"
            notices.say(.note(
                "\(selector) shows beside \(Self.describe(verdict)); \(tapping) its visible part",
                agent: "\(selector) at \(VerifyOutput.pointDescription(x: judging.point.x, y: judging.point.y)) is under \(Self.describe(verdict)); \(tapping) the part that shows at \(VerifyOutput.pointDescription(x: moved.point.x, y: moved.point.y))."
            ))
            return moved
        }
        guard failIfCovered, verdict.isEmptyViewDoubt else {
            let scroll = verdict.evidence == .systemBar ? Self.scrollClear(judging.target, of: verdict.cover, roots: judging.roots, viewport: judging.viewport, device: device) : nil
            try act(on: verdict, selector: selector, at: judging.point, viewport: judging.viewport, device: device, scrollHint: scroll)
            return resolution
        }
        guard await Self.showsOnScreen(judging.target, viewport: judging.viewport, backend: backend, device: device) else {
            try act(on: verdict, selector: selector, at: judging.point, viewport: judging.viewport, device: device, unread: true)
            return resolution
        }
        notices.say(.note(
            "\(selector) shows on screen under an empty \(verdict.cover.role.rawValue)",
            agent: "\(selector) has only an empty \(Self.describe(verdict)) over it by Android's drawing order, and a screenshot shows its text, so that view is no cover."
        ))
        return resolution
    }

    /// The tree cannot tell a screen's own empty wrapper from a veil, so its text in a screenshot decides, as a person would check it.
    @MainActor
    private static func showsOnScreen(_ target: UINode, viewport: UIFrame, backend: any DeviceBackend, device: DeviceID) async -> Bool {
        guard let label = target.normalizedLabel, let frame = target.frame, let png = try? await backend.screenshotPNG(for: device) else { return false }
        let read = await Timings.measure("cover-text") { await ScreenTextReader.lines(in: png, region: frame, viewport: viewport) }
        return ShownText.shows(label: label, in: read)
    }

    /// The front reading's verdict when the shared judgement already read this point on this tree, else the judge's own, with a hit-test on a simulator.
    @MainActor
    static func verdict(_ judging: Judging, in tree: UITree, hitTester: (any PointHitTesting)?, device: DeviceID, sure: Bool = false) async throws -> CoverVerdict? {
        let verdict: CoverVerdict?
        if let front = tree.front, judging.target.isSameElement(as: judging.matched),
           let index = ScreenStack.index(of: judging.matched, in: tree.roots), let judged = front.judged[index], judged.point == judging.point, !judged.unsure,
           !sure || judged.ownHit != nil || hitTester == nil {
            verdict = judged.verdict
        } else {
            var hit: UINode?
            if let hitTester {
                hit = try? await hitTester.hitTest(at: judging.point, on: device, appPIDs: judging.appPIDs)
            }
            verdict = judging.verdict(hit: hit)
            if sure, hitTester != nil, hit == nil, verdict == nil {
                let point = VerifyOutput.pointDescription(x: judging.point.x, y: judging.point.y)
                throw CLIError(
                    errorDescription: "Could not read what lies at \(point), so --fail-if-covered cannot say a tap would reach the target. Nothing was sent. Run it again.",
                    reason: .targetCovered,
                    hint: CommandScope.current.describeHint(device: device.rawValue)
                )
            }
        }
        guard let verdict, verdict.hitFoundTarget, let hitTester,
              await judging.isHiddenAtItsOwnPoint(verdict.cover, hitTester: hitTester, device: device) else {
            return verdict
        }
        return nil
    }

    /// At most this many parts beside a cover are read.
    static let partTries = 2

    /// The tap moved to the middle of a part of the target that a cover at `coverFrame` leaves showing, at least 8 pt across, where the simulator's hit-test finds the target itself; full-width parts first. Only a hit-test proves the part is not under something the tree leaves out.
    @MainActor
    static func reachablePart(of resolution: TapResolution, beside coverFrame: UIFrame, in tree: UITree, reader: FrontJudge.PointReader) async -> TapResolution? {
        for moved in clearParts(of: resolution, beside: coverFrame, in: tree).prefix(partTries) {
            guard let judging = Judging(moved, in: tree, beneath: false), judging.keyboard == nil,
                  let hit = await reader.read(at: judging.point),
                  judging.reachesPart(hit: hit) else { continue }
            return moved
        }
        return nil
    }

    /// The tap moved to the middle of each part of the target that a cover at `coverFrame` leaves showing, best first; empty when none is 8 pt across. A wide switch toggles only at its knob, so its tap keeps the knob's x, and a part without it does not count.
    static func clearParts(of resolution: TapResolution, beside coverFrame: UIFrame, in tree: UITree) -> [TapResolution] {
        guard let target = resolution.target, let frame = target.frame, let viewport = tree.viewport,
              let visible = AccessibilityTargetResolver.visibleRegion(of: target, frame: frame, viewport: viewport, roots: tree.roots),
              let overlap = visible.intersection(coverFrame) else { return [] }
        let knob = AccessibilityTargetResolver.isWideSwitch(target, frame: frame) ? resolution.point.x : nil
        return parts(of: visible, outside: overlap, minimum: frame).compactMap { part in
            if let knob, knob < part.x || knob > part.x + part.width { return nil }
            let point = UIPoint(x: knob ?? part.center.x, y: part.center.y)
            return AccessibilityTargetResolver.resolution(of: resolution, at: point, roots: tree.roots, viewport: viewport)
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
    @MainActor
    private func act(on verdict: CoverVerdict, selector: String, at point: UIPoint, viewport: UIFrame, device: DeviceID, unread: Bool = false, scrollHint: String? = nil) throws {
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        let cover = Self.describe(verdict)
        let tapping = dryRun ? "would \(gesture)" : gerund
        if verdict.isConfident, allowCovered {
            notices.say(.warning(
                "\(selector) is covered by \(cover); \(tapping) anyway (--allow-covered)",
                agent: "\(selector) at \(pointText) is covered by \(cover) (\(Self.evidence(verdict.evidence))); \(tapping) anyway because of --allow-covered."
            ))
            return
        }
        if verdict.evidence == .systemBar {
            let fix = scrollHint == nil ? "Nothing scrolls it clear, so the app needs to draw it above the bar" : "Scroll it clear of the bar, then retry"
            throw CLIError(
                errorDescription: "\(selector) at \(pointText) is under \(cover), which takes every touch there, so the \(gesture) would land on the bar. Nothing was sent. \(fix); or \(override).",
                reason: .targetCovered,
                hint: scrollHint ?? CommandScope.current.describeHint(device: device.rawValue),
                coveredBy: CoverReport(verdict)
            )
        }
        if verdict.evidence == .devMenuTouchArea, let drag = Self.dragClear(verdict.cover, viewport: viewport, device: device) {
            throw CLIError(
                errorDescription: "\(selector) at \(pointText) is under the dev menu button, \(cover) (\(Self.evidence(verdict.evidence))), so the \(gesture) would open the dev menu. Nothing was sent. Drag the button clear, then retry; or \(override).",
                reason: .targetCovered,
                hint: drag,
                coveredBy: CoverReport(verdict)
            )
        }
        if verdict.isConfident {
            throw CLIError(
                errorDescription: "\(selector) at \(pointText) is covered by \(cover) (\(Self.evidence(verdict.evidence))), so the \(gesture) would land on it. Nothing was sent. Close what covers it or wait for it to go (--wait-timeout), or \(override).",
                reason: .targetCovered,
                hint: CommandScope.current.describeHint(device: device.rawValue),
                coveredBy: CoverReport(verdict)
            )
        }
        let unseen = unread ? " Its text does not show in a screenshot." : ""
        let message = "\(selector) at \(pointText) may be covered by \(cover); the \(gesture) may land on it.\(unseen)"
        if failIfCovered {
            throw CLIError(errorDescription: "\(message) Nothing was sent.", reason: .targetCovered, hint: CommandScope.current.describeHint(device: device.rawValue), coveredBy: CoverReport(verdict))
        }
        notices.say(.warning(
            "\(selector) may be covered by \(cover); the \(gesture) may land on it",
            agent: message + (stopFlag.map { " Pass \($0) to stop instead." } ?? "")
        ))
    }

    /// The swipe that scrolls `target` away from the system bar `bar`, over the part of its scroll view clear of the bar; nil when nothing around it scrolls.
    @MainActor
    static func scrollClear(_ target: UINode, of bar: UINode, roots: [UINode], viewport: UIFrame, device: DeviceID) -> String? {
        guard let barFrame = bar.frame,
              let scroller = AccessibilityTargetResolver.ancestorsOf(target, in: roots).last(where: { [.scrollView, .list].contains($0.role) && $0.hasPositiveFrame }),
              let shown = scroller.frame?.intersection(viewport) else { return nil }
        let below = barFrame.y > shown.y
        let top = below ? shown.y : max(shown.y, barFrame.y + barFrame.height)
        let bottom = below ? min(shown.y + shown.height, barFrame.y) : shown.y + shown.height
        guard bottom - top >= 40 else { return nil }
        let swipe = DevMenuDriver.scrollSwipe(up: below, in: UIFrame(x: shown.x, y: top, width: shown.width, height: bottom - top))
        return "offsider swipe --start-x \(swipe.x) --start-y \(swipe.from) --end-x \(swipe.x) --end-y \(swipe.to) --duration 0.5 --hold-end 300\(CommandScope.current.appArgument(device: device.rawValue)) --device \(device.rawValue)"
    }

    /// The drag that moves the dev menu button at `button`'s frame into the other half of the screen.
    @MainActor
    static func dragClear(_ button: UINode, viewport: UIFrame, device: DeviceID) -> String? {
        guard let centre = button.frame?.center else { return nil }
        let bottom = viewport.y + viewport.height
        let endY = centre.y >= viewport.y + viewport.height / 2 ? max(viewport.y + 40, centre.y - 240) : min(bottom - 40, centre.y + 240)
        let x = VerifyOutput.number(centre.x)
        return "offsider drag --start-x \(x) --start-y \(VerifyOutput.number(centre.y)) --end-x \(x) --end-y \(VerifyOutput.number(endY)) --duration 0.8 --hold-end 300\(CommandScope.current.appArgument(device: device.rawValue)) --device \(device.rawValue)"
    }

    /// A prompt another process draws over the app takes the tap, so it refuses unless `--allow-covered`.
    private func refuse(under prompt: SystemPrompt, verdict: CoverVerdict, selector: String, at point: UIPoint, viewport: UIFrame, device: DeviceID) throws {
        if allowCovered {
            let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
            let tapping = dryRun ? "would tap" : "tapping"
            notices.say(.warning(
                "\(selector) is under \(prompt.summary); \(tapping) anyway (--allow-covered)",
                agent: "\(selector) at \(pointText) is under \(prompt.summary); \(tapping) anyway because of --allow-covered."
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
    static func logBoxToasts(reaching target: UINode, at point: UIPoint, inset: Double, on ground: CoverGround, besides found: [UINode]) -> [UINode] {
        ground.logBoxToasts.filter { node in
            guard let area = KnownOverlays.logBoxTouchArea(of: node, in: ground.viewport, inset: inset),
                  area.contains(point) || CoverJudge.reaches(area, target.frame),
                  !found.contains(where: { $0.isSameElement(as: node) }),
                  !node.contains(where: { $0.isSameElement(as: target) }) else { return false }
            return !ground.stack.isBeneath(node, in: ground.tree)
        }
    }

    /// `button "Buy" (197, 793) 189x45 on stack-test-full-page-1`.
    static func describe(_ verdict: CoverVerdict) -> String {
        var parts = verdict.evidence == .systemBar ? [] : [verdict.cover.role.rawValue]
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
        case .devMenuTouchArea: return "its touch area reaches past its icon there"
        case .systemBar: return "Android's system bar takes touches there"
        }
    }

    /// A confident or refused cover, which a wait may outlast.
    static func isRefusal(_ error: any Error) -> Bool {
        (error as? CLIError)?.reason == .targetCovered
    }

    /// How long a keyboard over the target is read again, so one caught as it appears or changes mode does not refuse.
    static let keyboardSettle: TimeInterval = 1

    /// How long a refused cover is read again straight after an input, as a page just left can stay in the tree over its successor while it goes.
    static let coverSettle: TimeInterval = 1
    /// How recent an input must be for `coverSettle` to apply.
    static let coverSettleWindow: TimeInterval = 2

    /// `coverSettle` when the device's last input is recent, else nothing, so a cover that has simply been there refuses at once.
    @MainActor
    static func coverSettle(lastInput: Date?, now: Date? = nil) -> TimeInterval {
        guard let lastInput, (now ?? TreeCacheEnvironment.current.now()).timeIntervalSince(lastInput) < coverSettleWindow else { return 0 }
        return coverSettle
    }

    static func isKeyboardRefusal(_ error: any Error) -> Bool {
        (error as? CLIError)?.reason == .targetUnderKeyboard
    }

    static func isDisabledRefusal(_ error: any Error) -> Bool {
        (error as? CLIError)?.reason == .targetDisabled
    }
}
