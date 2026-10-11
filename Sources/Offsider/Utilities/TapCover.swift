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

    /// Throws `target_under_keyboard` or `target_covered`, or prints a warning; returns when the tap may go ahead.
    @MainActor
    func check(_ resolution: TapResolution, selector: String, tree: UITree, backend: any DeviceBackend, device: DeviceID) async throws {
        guard let target = resolution.target ?? resolution.matched, let viewport = tree.viewport else {
            return
        }
        let android = tree.platform == .android
        // Before the hit-test, which on a simulator can answer with the field beneath the keyboard.
        if AccessibilityTargetResolver.keyboardCover(resolution, in: tree) != nil {
            throw Tap.keyboardCoverError(selector: selector, at: resolution.point, device: device)
        }
        // On Android the keyboard's window bounds have decided; its root view spans the screen, so it leaves the judging.
        let roots = android ? tree.roots.filter { $0.role != .keyboard } : tree.roots
        var candidates = resolution.coverCandidates
        if android {
            candidates.removeAll { AccessibilityTargetResolver.isUnderKeyboard($0, in: tree.roots) }
        }
        let stack = roots.count == tree.roots.count ? resolution.stack ?? ScreenStack.build(roots: roots, viewport: viewport) : ScreenStack.build(roots: roots, viewport: viewport)
        let matched = resolution.matched ?? target
        let beneath = stack.isBeneath(target, in: roots) || stack.isBeneath(matched, in: roots)
        let point = UIPoint(x: resolution.point.x, y: resolution.point.y)
        let logBoxInset = KnownOverlays.logBoxTopInset(in: tree)
        if logBoxInset > 0 {
            candidates += Self.logBoxToasts(reaching: target, at: point, inset: logBoxInset, roots: roots, viewport: viewport, stack: stack, besides: candidates)
        }
        // Empty containers never cover, but the empty host of another process's prompt is worth a hit-test.
        let promptHost = !android && SystemPrompt.hasHost(over: target, in: tree)
        guard android || !candidates.isEmpty || beneath || promptHost else {
            return
        }
        var hit: UINode?
        let hitTester = android ? nil : backend as? any PointHitTesting
        if let hitTester {
            hit = try? await hitTester.hitTest(at: point, on: device, appPIDs: promptHost ? SystemPrompt.pids(in: roots) : [])
        }
        guard let verdict = CoverJudge.judge(
            target: target, matched: matched, point: point, candidates: candidates, roots: roots, viewport: viewport, stack: stack, hit: hit,
            logBoxInset: logBoxInset, otherProcessCovers: promptHost
        ) else {
            return
        }
        if verdict.evidence == .otherProcess, let hitTester, let pid = verdict.cover.iosPID {
            let prompt = await SystemPromptProbe.prompt(of: verdict.cover, pid: pid, in: tree, hitTester: hitTester, device: device)
            try refuse(under: prompt, verdict: verdict, selector: selector, at: point, viewport: viewport, device: device)
            return
        }
        if AccessibilityTargetResolver.isUnderKeyboard(verdict.cover, in: roots) {
            throw Tap.keyboardCoverError(selector: selector, at: resolution.point, device: device)
        }
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        let cover = Self.describe(verdict)
        if verdict.isConfident, allowCovered {
            print("Warning: \(selector) at \(pointText) is covered by \(cover) (\(Self.evidence(verdict.evidence))); tapping anyway because of --allow-covered.", to: &standardError)
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
        print("Warning: \(message) Pass --fail-if-covered to stop instead.", to: &standardError)
    }

    /// A prompt another process draws over the app takes the tap, so it refuses unless `--allow-covered`.
    private func refuse(under prompt: SystemPrompt, verdict: CoverVerdict, selector: String, at point: UIPoint, viewport: UIFrame, device: DeviceID) throws {
        if allowCovered {
            let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
            print("Warning: \(selector) at \(pointText) is under \(prompt.summary); tapping anyway because of --allow-covered.", to: &standardError)
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

    /// `button 'Buy' (197, 793) 189x45 on stack-test-full-page-1`.
    static func describe(_ verdict: CoverVerdict) -> String {
        var parts = [verdict.cover.role.rawValue]
        if let name = verdict.cover.normalizedLabel ?? verdict.cover.normalizedID {
            parts.append("'\(SelectorText.truncated(name))'")
        }
        if let frame = verdict.cover.frame {
            parts.append(frame.summary)
        }
        if let screen = verdict.screen, screen != verdict.cover.normalizedID {
            parts.append("on \(SelectorText.truncated(screen))")
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
