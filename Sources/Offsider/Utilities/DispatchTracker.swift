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
    /// The backend that reads the screen for the app guard; nil sends unguarded, which only a test's bare session does.
    let backend: (any DeviceBackend)?

    init(_ base: any InputSession, backend: (any DeviceBackend)? = nil) {
        self.base = base
        self.backend = backend
    }

    static func wrapping(_ base: any InputSession, backend: (any DeviceBackend)? = nil) -> TrackedInputSession {
        if let tracked = base as? TrackedInputSession { return tracked }
        if let text = base as? any TextInputSession { return TrackedTextInputSession(text, backend: backend) }
        return TrackedInputSession(base, backend: backend)
    }

    /// Refuses, before anything is sent, an input that would land on a guarded control of the app in front.
    func requireUnguarded(_ event: InputEvent) async throws {
        guard let backend else { return }
        try await AppGuard.check(event, backend: backend, device: device)
    }

    var device: DeviceID { base.device }

    func perform(_ event: InputEvent) async throws {
        try Self.requireUsable(event)
        try await requireUnguarded(event)
        defer { DeviceActivityLedger.current.recordInput(on: device) }
        try await DispatchTracker.current.sending { try await base.perform(event) }
    }

    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        try Self.requireUsable(.composite([.tapAt(x: point.x, y: point.y), .delay(preDelay ?? 0), .delay(postDelay ?? 0)]))
        try await requireUnguarded(.tapAt(x: point.x, y: point.y))
        defer { DeviceActivityLedger.current.recordInput(on: device) }
        try await DispatchTracker.current.sending {
            try await base.performPhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay)
        }
    }

    func close() async {
        await base.close()
    }

    /// Refuses, before anything is sent, numbers no backend could turn into input.
    static func requireUsable(_ event: InputEvent) throws {
        guard let problem = event.unusableNumber else { return }
        throw CLIError(errorDescription: "Refused input: \(problem). Nothing was sent.", reason: .usage)
    }
}

@MainActor
final class TrackedTextInputSession: TrackedInputSession, TextInputSession {
    private let text: any TextInputSession

    init(_ text: any TextInputSession, backend: (any DeviceBackend)? = nil) {
        self.text = text
        super.init(text, backend: backend)
    }

    /// A newline presses Return, which a guarded screen's default control answers to.
    private func requireUnguarded(text value: String) async throws {
        guard value.contains(where: \.isNewline) else { return }
        try await requireUnguarded(.shortKeyPress(40))
    }

    func typeText(_ value: String) async throws {
        try await requireUnguarded(text: value)
        defer { DeviceActivityLedger.current.recordInput(on: device) }
        try await DispatchTracker.current.sending { try await text.typeText(value) }
    }

    func replaceText(_ value: String) async throws {
        try await requireUnguarded(text: value)
        defer { DeviceActivityLedger.current.recordInput(on: device) }
        try await DispatchTracker.current.sending { try await text.replaceText(value) }
    }
}

extension DeviceBackend {
    func openTrackedSession(for id: DeviceID) async throws -> any InputSession {
        TrackedInputSession.wrapping(try await openInputSession(for: id), backend: self)
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
