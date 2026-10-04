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

    /// Runs `body`, writes the tree cache, then closes every adopted backend in reverse adoption order, also when `body` throws.
    func run(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await commitTreeCache()
            await closeAll()
            claims.releaseAll()
            throw error
        }
        await commitTreeCache()
        await closeAll()
        claims.releaseAll()
    }

    /// Also after a failure: a failed input command may still have dispatched.
    func commitTreeCache() async {
        guard let command else { return }
        await TreeCache.commit(command: command, effect: CommandEffect.of(command), claimed: claims.heldKeys, backends: adopted)
    }

    /// Idempotent: each backend leaves the list before its close starts, so a slow close never skips or repeats another.
    func closeAll() async {
        while let backend = adopted.popLast() {
            await backend.close()
        }
    }
}
