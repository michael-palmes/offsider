import Foundation
import OffsiderCore

/// The one read at the screen's centre that standalone describe-ui and a missed wait or assert make; taps, verify polls and batch never do.
enum PresentationCheck {
    /// The longest a command waits on the read; it only explains, so a slower one is dropped rather than holding the output.
    static let limit: TimeInterval = 1.5

    /// What the read found on `tree`'s screen; nil when the backend cannot read a point, the tree has no centre, or the read failed.
    @MainActor
    static func finding(for tree: UITree, backend: any DeviceBackend, device: DeviceID) async -> PresentationFinding? {
        guard let prober = backend as? any PresentationProbing, let point = PresentationProbe.point(in: tree) else { return nil }
        guard let hit = await bounded({ try await prober.probe(at: point, on: device) }) else { return nil }
        return finding(for: tree, hit: hit)
    }

    /// Starts the read at the screen's centre before the tree read, so the simulator answers both at once; nil when the backend cannot read a point.
    @MainActor
    static func start(backend: any DeviceBackend, device: DeviceID) async -> Pending? {
        guard let prober = backend as? any PresentationProbing, let size = try? await backend.screenSize(for: device), size.width > 0, size.height > 0 else {
            return nil
        }
        let point = UIPoint(x: size.width / 2, y: size.height / 2)
        let read = Task { @MainActor in (try? await prober.probe(at: point, on: device)) ?? nil }
        // Lets the read send its request before the tree read takes the main actor.
        await Task.yield()
        return Pending(read: read)
    }

    /// A read started with `start`; the `probe` phase is how long the command waits for it once the tree is in.
    struct Pending {
        let read: Task<UINode?, Never>

        @MainActor
        func finding(for tree: UITree) async -> PresentationFinding? {
            defer { read.cancel() }
            guard let hit = await PresentationCheck.bounded({ await read.value }) else { return nil }
            return PresentationCheck.finding(for: tree, hit: hit)
        }
    }

    /// The read's answer, or nil when it failed or took longer than `limit`.
    @MainActor
    static func bounded(_ read: @escaping @MainActor () async throws -> UINode?) async -> UINode? {
        await Timings.measure("probe") {
            (try? await DoctorProbes.withTimeout(limit, operation: "Reading the screen's centre", read)) ?? nil
        }
    }

    private static func finding(for tree: UITree, hit: UINode) -> PresentationFinding {
        PresentationProbe.finding(in: tree, hit: hit) { pid in Int32(exactly: pid).flatMap(ProcessPath.of(pid:)) }
    }
}
