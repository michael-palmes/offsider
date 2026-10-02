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
        return BatchReadResult(outcome, success: successLine(outcome), failure: failureLine(outcome))
    }
}

extension Assert: BatchReadable {
    func runInBatch(context: BatchContext, logger: OffsiderLogger) async throws -> BatchReadResult {
        let outcome = try await context.watchdog.guarding(bound: 0, device: context.device.rawValue) {
            try await evaluate(on: context.route, logger: logger, tree: context.pollingTreeSource())
        }
        return BatchReadResult(outcome, success: successLine(outcome), failure: failureLine(outcome))
    }
}

extension DescribeUI: BatchReadable {
    func runInBatch(context: BatchContext, logger: OffsiderLogger) async throws -> BatchReadResult {
        let tree: UITree
        if let point = try parsedPoint() {
            tree = try await context.backend.accessibilityTree(for: context.device, point: point)
        } else {
            tree = try await context.accessibilityTree()
        }
        let described = await Self.withScreen(tree, on: context.route)
        let rendered = String(decoding: try output.render(described), as: UTF8.self)
        return BatchReadResult(detail: .describe(described, try output.renderOptions()), output: rendered)
    }
}

extension Screenshot: BatchReadable {
    func runInBatch(context: BatchContext, logger: OffsiderLogger) async throws -> BatchReadResult {
        let report = try await take(try request(), on: context.route)
        guard let comparison = report.comparison else {
            return BatchReadResult(detail: .screenshot(report), output: report.path.map { $0 + "\n" })
        }
        if comparison.outcome == .unchanged {
            return BatchReadResult(detail: .screenshot(report), unmet: comparison.summary)
        }
        return BatchReadResult(detail: .screenshot(report), note: comparison.summary)
    }
}
