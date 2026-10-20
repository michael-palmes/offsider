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

    /// Takes the agent's banner line instead of stderr, for tests; nil writes it, in every mode, through the console.
    var bannerNote: ((String) -> Void)?

    func noteRoute(_ route: DeviceRouter.Route) {
        routes.append(route)
        guard let allowance = route.allowance, announced.insert("\(allowance.platform.rawValue) \(allowance.key)").inserted else { return }
        let managed = DevicePolicyGate.current.policy().managed.present
        let line = Self.banner(for: allowance, managed: managed)
        if let bannerNote {
            bannerNote(line)
            return
        }
        let console = Console.current
        let err = console.err
        // Never a notice: a safety line is never deduped or capped.
        console.data(err.profile == .person ? Self.personBanner(for: allowance, managed: managed, now: Date(), timeZone: .current, canvas: err.canvas) : line + "\n", to: .err)
    }

    /// A person's one dim line: `🔐  Driving Test iPhone · allowed until 18:00 · com.example.app only`, broken between parts when narrow.
    nonisolated static func personBanner(for allowance: DeviceAllowance, managed: Bool, now: Date, timeZone: TimeZone, canvas: Canvas) -> String {
        let style = canvas.style
        let lead = style.mark(.lock) + (style.ascii ? " " : "  ")
        let indent = String(repeating: " ", count: TerminalText.width(lead))
        let parts = [
            "Driving \(AccessStatusScreen.name(allowance))", "allowed " + AllowScreen.until(allowance.expires, now: now, timeZone: timeZone), AllowScreen.apps(allowance.apps),
        ] + (managed ? ["managed policy applies"] : [])
        // Two columns short, for the separator `pack` leaves at the end of a broken line.
        let lines = PromptScreen.pack(parts, separator: " \(style.dot) ", width: max(canvas.usable - indent.count - 2, 10))
        return lines.enumerated().map { ($0 == 0 ? lead : indent) + style.dim($1) }.joined(separator: "\n") + "\n"
    }

    /// The one line a command prints before it drives a physical device.
    nonisolated static func banner(for allowance: DeviceAllowance, managed: Bool) -> String {
        let kind = allowance.platform == .ios ? "iPhone or iPad" : "Android phone"
        let until = allowance.expires.map { "allowed until \(ProcessStamp.timestamp($0))" } ?? "allowed until removed"
        let named = allowance.apps.map { $0 == DeviceAllowance.wholeDevicePin ? "any app and all logs" : $0 }
        let apps = named.isEmpty ? "" : " for \(named.joined(separator: ", "))"
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
