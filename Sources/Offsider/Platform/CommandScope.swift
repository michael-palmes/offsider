import Foundation
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

    /// Physical devices this process has announced, so the banner prints once per device.
    private var announced: Set<String> = []

    /// Where the physical-device banner goes; stderr, also under `--json`.
    var bannerNote: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }

    func noteRoute(_ route: DeviceRouter.Route) {
        routes.append(route)
        guard let allowance = route.allowance, announced.insert("\(allowance.platform.rawValue) \(allowance.key)").inserted else { return }
        bannerNote(Self.banner(for: allowance, managed: DevicePolicyGate.current.policy().managed.present))
    }

    /// The one line a command prints before it drives a physical device.
    nonisolated static func banner(for allowance: DeviceAllowance, managed: Bool) -> String {
        let kind = allowance.platform == .ios ? "iPhone or iPad" : "Android phone"
        let until = allowance.expires.map { "allowed until \(ProcessStamp.timestamp($0))" } ?? "allowed until removed"
        let apps = allowance.apps.isEmpty ? "" : " for \(allowance.apps.joined(separator: ", "))"
        return "Offsider: driving physical \(kind) \"\(allowance.name)\" (\(allowance.key)), \(until)\(apps) (managed policy: \(managed ? "applies" : "none")). "
            + "offsider device-access remove --device \(allowance.key) withdraws it."
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
            let status = ErrorReporter.status(for: error)
            EvidenceRecorder.current.finishAll(exit: status.exit, reason: status.reason)
            let error = await screenHint(for: error)
            await commitTreeCache(failed: true)
            await closeAll()
            claims.releaseAll()
            throw error
        }
        EvidenceRecorder.current.finishAll(exit: 0, reason: nil)
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
