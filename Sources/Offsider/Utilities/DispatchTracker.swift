import Foundation
import OffsiderCore

/// Whether this process has sent input: `no` until a send begins, `unknown` while one runs or after one throws, `yes` once it returns.
@MainActor
final class DispatchTracker {
    /// One per process; a test binds its own so parallel tests do not share one.
    @TaskLocal static var current = DispatchTracker()

    private(set) var state: DispatchState = .no

    nonisolated init() {}

    func reset() {
        state = .no
    }

    func sending<T>(_ body: () async throws -> T) async rethrows -> T {
        state = .unknown
        let result = try await body()
        state = .yes
        return result
    }
}

/// Records every send through `DispatchTracker.current`, so a failure can say whether input may have reached the device.
@MainActor
class TrackedInputSession: InputSession {
    let base: any InputSession

    init(_ base: any InputSession) {
        self.base = base
    }

    static func wrapping(_ base: any InputSession) -> TrackedInputSession {
        if let tracked = base as? TrackedInputSession { return tracked }
        if let text = base as? any TextInputSession { return TrackedTextInputSession(text) }
        return TrackedInputSession(base)
    }

    var device: DeviceID { base.device }

    func perform(_ event: InputEvent) async throws {
        try await DispatchTracker.current.sending { try await base.perform(event) }
    }

    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        try await DispatchTracker.current.sending {
            try await base.performPhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay)
        }
    }

    func close() async {
        await base.close()
    }
}

@MainActor
final class TrackedTextInputSession: TrackedInputSession, TextInputSession {
    private let text: any TextInputSession

    init(_ text: any TextInputSession) {
        self.text = text
        super.init(text)
    }

    func typeText(_ value: String) async throws {
        try await DispatchTracker.current.sending { try await text.typeText(value) }
    }

    func replaceText(_ value: String) async throws {
        try await DispatchTracker.current.sending { try await text.replaceText(value) }
    }
}

extension DeviceBackend {
    func openTrackedSession(for id: DeviceID) async throws -> any InputSession {
        TrackedInputSession.wrapping(try await openInputSession(for: id))
    }

    /// `perform(_:on:)` with the send recorded.
    func performTracked(_ event: InputEvent, on id: DeviceID) async throws {
        let session = try await openTrackedSession(for: id)
        do {
            try await session.perform(event)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }
}
