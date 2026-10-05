import OffsiderCore

/// The backends one command built; each is closed once when the command ends, after success or failure.
@MainActor
final class CommandScope {
    nonisolated static let current = CommandScope()

    /// In adoption order; empty again once closed.
    private(set) var adopted: [any DeviceBackend] = []

    /// Released after every backend has closed, so an Android helper has quit before another command can claim the device.
    let claims: DeviceClaims

    /// The command path for the tree cache; nil leaves the cache alone (tests that only check closing).
    private(set) var command: String?

    /// Each device the router chose, for the screen check after a failure.
    private(set) var routes: [DeviceRouter.Route] = []

    /// Set by the first screen check, so a report written before the command ends and its final error share one probe.
    private var screenChecked = false

    nonisolated init(claims: DeviceClaims = .current) {
        self.claims = claims
    }

    func configure(command: String) {
        self.command = command
    }

    /// Adopting the same backend twice keeps one entry, so it is closed once.
    @discardableResult
    func adopt<Backend: DeviceBackend>(_ backend: Backend) -> Backend {
        if !adopted.contains(where: { $0 === backend }) {
            adopted.append(backend)
        }
        return backend
    }

    func noteRoute(_ route: DeviceRouter.Route) {
        routes.append(route)
    }

    /// The screen check for a failure, once per command; later calls return `error` unchanged.
    func screenHint(for error: any Error, note: (String) -> Void = ScreenStateHint.writeNote) async -> any Error {
        guard !screenChecked else { return error }
        screenChecked = true
        return await ScreenStateHint.annotate(error, routes: routes, note: note)
    }

    /// Runs `body`, writes the tree cache, then closes every adopted backend in reverse adoption order, also when `body` throws.
    func run(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            let error = await screenHint(for: error)
            await commitTreeCache(failed: true)
            await closeAll()
            claims.releaseAll()
            throw error
        }
        await commitTreeCache()
        await closeAll()
        claims.releaseAll()
    }

    /// Also after a failure: a failed input command may still have dispatched, unless the tracker saw nothing sent.
    func commitTreeCache(failed: Bool = false) async {
        guard let command else { return }
        let sentNothing = failed && DispatchTracker.current.state == .no
        await TreeCache.commit(command: command, effect: CommandEffect.of(command), claimed: claims.heldKeys, backends: adopted, sentNothing: sentNothing)
    }

    /// Idempotent: each backend leaves the list before its close starts, so a slow close never skips or repeats another.
    func closeAll() async {
        while let backend = adopted.popLast() {
            await backend.close()
        }
    }
}
