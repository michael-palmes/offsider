import ArgumentParser
import Foundation
import OffsiderCore

/// What a read step leaves behind: its record detail, its human output, and whether its condition was not met.
struct BatchReadResult {
    var detail: BatchStepRecord.Detail
    /// Printed to stdout without `batch --json`; dropped with it, since the record carries the same data.
    var output: String?
    /// A status line: stdout without `batch --json`, stderr with it.
    var note: String?
    /// Why the condition was not met; the step then fails with exit 5.
    var unmet: String?

    init(detail: BatchStepRecord.Detail, output: String? = nil, note: String? = nil, unmet: String? = nil) {
        self.detail = detail
        self.output = output
        self.note = note
        self.unmet = unmet
    }

    init(_ outcome: WaitOutcome, success: String, failure: String) {
        self.init(detail: .wait(outcome))
        if outcome.met {
            note = success
        } else {
            unmet = failure.hasPrefix("✗ ") ? String(failure.dropFirst(2)) : failure
        }
    }

    /// The outcome as `Wait.report` shows it: screen text redacted, with the note when the check matched on hidden text.
    @MainActor
    static func redacted(_ outcome: WaitOutcome, success: String, failure: String, checked: ElementSelectorOptions?) -> BatchReadResult {
        let mask = (try? AmbientMasks.treeMask()) ?? .none
        return BatchReadResult(
            Wait.shown(outcome, mask: mask),
            success: success + Wait.redactionNote(outcome, checked: checked, mask: mask),
            failure: LogRedactor.redactValue(failure).text
        )
    }
}

/// A command that can run as a batch step after the previous step's input has been sent.
@MainActor
protocol BatchReadable {
    func runInBatch(context: BatchContext, logger: OffsiderLogger) async throws -> BatchReadResult
}

extension BatchContext {
    var route: DeviceRouter.Route {
        DeviceRouter.Route(backend: backend, device: device)
    }
}

extension Wait: BatchReadable {
    func runInBatch(context: BatchContext, logger: OffsiderLogger) async throws -> BatchReadResult {
        let readsTree = selector.query != nil || (settled && settleBy != .screen)
        let outcome = try await context.watchdog.guarding(bound: watchdogBound, device: context.device.rawValue) {
            try await evaluate(on: context.route, logger: logger, tree: context.pollingTreeSource())
        }
        if !readsTree {
            // Time passed without a tree read, so the cached tree may be stale.
            context.invalidateTree()
        }
        return .redacted(outcome, success: successLine(outcome), failure: failureLine(outcome), checked: selector.query == nil ? nil : selector)
    }
}

extension Assert: BatchReadable {
    func runInBatch(context: BatchContext, logger: OffsiderLogger) async throws -> BatchReadResult {
        let outcome = try await context.watchdog.guarding(bound: 0, device: context.device.rawValue) {
            try await evaluate(on: context.route, logger: logger, tree: context.pollingTreeSource())
        }
        return .redacted(outcome, success: successLine(outcome), failure: failureLine(outcome), checked: selector)
    }
}

extension DescribeUI: BatchReadable {
    func runInBatch(context: BatchContext, logger: OffsiderLogger) async throws -> BatchReadResult {
        if diff {
            throw ValidationError("Batch describe-ui steps do not take --diff. Run describe-ui --diff after the batch.")
        }
        try await Self.requireActive(displayOption, on: context.route, deviceName: context.device.rawValue)
        var tree: UITree
        if let point = try parsedPoint() {
            tree = try await context.backend.accessibilityTree(for: context.device, point: point)
        } else {
            tree = try await context.accessibilityTree()
            tree.systemPrompt = await SystemPromptProbe.find(in: tree, backend: context.backend, device: context.device)
        }
        let described = try await Self.shown(await Self.withScreen(tree, on: context.route), on: context.route)
        let rendered = String(decoding: try output.render(described), as: UTF8.self)
        return BatchReadResult(detail: .describe(described, try output.renderOptions()), output: rendered)
    }
}

extension Screenshot: BatchReadable {
    func runInBatch(context: BatchContext, logger: OffsiderLogger) async throws -> BatchReadResult {
        let masks = masksWithRunDefaults(try maskPlan(batchDefault: context.maskSecure))
        let report = try await take(try request(), on: context.route, masks: masks) { try await context.accessibilityTree() }
        guard let comparison = report.comparison else {
            return BatchReadResult(detail: .screenshot(report), output: report.path.map { $0 + "\n" })
        }
        if !comparison.met {
            return BatchReadResult(detail: .screenshot(report), unmet: comparison.summary)
        }
        return BatchReadResult(detail: .screenshot(report), note: comparison.summary)
    }
}
