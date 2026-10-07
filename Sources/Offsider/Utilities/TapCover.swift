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
        let roots = tree.roots
        let android = tree.platform == .android
        if android, AccessibilityTargetResolver.keyboardCover(resolution, in: tree) != nil {
            throw Tap.keyboardCoverError(selector: selector, at: resolution.point, device: device)
        }
        var candidates = resolution.coverCandidates
        if android {
            candidates.removeAll { AccessibilityTargetResolver.isUnderKeyboard($0, in: roots) }
        }
        let stack = resolution.stack ?? ScreenStack.build(roots: roots, viewport: viewport)
        let matched = resolution.matched ?? target
        let beneath = stack.isBeneath(target, in: roots) || stack.isBeneath(matched, in: roots)
        guard android || !candidates.isEmpty || beneath else {
            return
        }
        let point = UIPoint(x: resolution.point.x, y: resolution.point.y)
        var hit: UINode?
        if !android, let hitTester = backend as? any PointHitTesting {
            hit = try? await hitTester.hitTest(at: point, on: device)
        }
        guard let verdict = CoverJudge.judge(
            target: target, matched: matched, point: point, candidates: candidates, roots: roots, viewport: viewport, stack: stack, hit: hit
        ) else {
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
        }
    }

    /// A confident or refused cover, which a wait may outlast.
    static func isRefusal(_ error: any Error) -> Bool {
        (error as? CLIError)?.reason == .targetCovered
    }
}
