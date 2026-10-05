import Foundation
import OffsiderCore

@MainActor
struct BatchPlanRunner {
    let session: any InputSession
    let logger: OffsiderLogger

    func run(_ plan: BatchPlan) async throws {
        var pendingMergeable: [InputEvent] = []

        func flushPending() async throws {
            guard !pendingMergeable.isEmpty else { return }
            let event = pendingMergeable.count == 1 ? pendingMergeable[0] : InputEvent.composite(pendingMergeable)
            try await session.perform(event)
            pendingMergeable.removeAll(keepingCapacity: true)
        }

        for primitive in plan.primitives {
            switch primitive {
            case .hidMergeable(let event):
                pendingMergeable.append(event)
            case .hidBarrier(let event):
                try await flushPending()
                // A barrier prevents event coalescing; failures propagate without replaying
                // this event or any earlier event in the batch.
                try await session.perform(event)
            case .hostSleep(let seconds):
                try await flushPending()
                guard seconds > 0 else { continue }

                try await Task.sleep(for: .seconds(seconds))
            case .physicalTap(let point, let preDelay, let postDelay):
                try await flushPending()
                try await session.performPhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay)
            case .text(let text, let replace):
                try await flushPending()
                guard let textSession = session as? any TextInputSession else {
                    throw CLIError(errorDescription: "This device's input session cannot type text as one step.", reason: .internalError)
                }
                if replace {
                    try await textSession.replaceText(text)
                } else {
                    try await textSession.typeText(text)
                }
            case .run(let body):
                try await flushPending()
                try await body(session)
            }
        }

        try await flushPending()
    }
}
