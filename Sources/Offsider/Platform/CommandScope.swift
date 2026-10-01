import OffsiderCore

/// The backends one command built; each is closed once when the command ends, after success or failure.
@MainActor
final class CommandScope {
    nonisolated static let current = CommandScope()

    /// In adoption order; empty again once closed.
    private(set) var adopted: [any DeviceBackend] = []

    nonisolated init() {}

    /// Adopting the same backend twice keeps one entry, so it is closed once.
    @discardableResult
    func adopt<Backend: DeviceBackend>(_ backend: Backend) -> Backend {
        if !adopted.contains(where: { $0 === backend }) {
            adopted.append(backend)
        }
        return backend
    }

    /// Runs `body`, then closes every adopted backend in reverse adoption order, also when `body` throws.
    func run(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await closeAll()
            throw error
        }
        await closeAll()
    }

    /// Idempotent: each backend leaves the list before its close starts, so a slow close never skips or repeats another.
    func closeAll() async {
        while let backend = adopted.popLast() {
            await backend.close()
        }
    }
}
