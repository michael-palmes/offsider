import Darwin
import FBSimulatorControl
import Foundation
import OffsiderCore

/// An open automation session, which keeps Accessibility loaded for every app on the simulator until it is invalidated.
protocol HeldAccessibilitySession: AnyObject, Sendable {
    var isValid: Bool { get }
    func invalidate()
}

extension FBSimulatorAccessibilityHold: HeldAccessibilitySession, @unchecked @retroactive Sendable {}

/// The broker's automation session: opened in the background once it listens, opened again when it dies, closed when the broker stops.
final class BrokerAccessibilityHold: @unchecked Sendable {
    /// A session that failed or died is not tried again sooner than this, so a simulator that refuses costs one try a while.
    static let reopenInterval: Duration = .seconds(5)

    private let lock = NSLock()
    private let open: @Sendable () -> (any HeldAccessibilitySession)?
    private let reopenAfter: Duration
    private let log: @Sendable (String) -> Void
    private let queue: DispatchQueue
    private var session: (any HeldAccessibilitySession)?
    /// Names the open session, so a command can tell the one it was told of from one opened after it ended.
    private var token: String?
    private var opening = false
    private var closed = false
    private var lastTry: ContinuousClock.Instant?

    init(
        open: @escaping @Sendable () -> (any HeldAccessibilitySession)?,
        reopenAfter: Duration = BrokerAccessibilityHold.reopenInterval,
        queue: DispatchQueue = DispatchQueue(label: "offsider.accessibility-hold"),
        log: @escaping @Sendable (String) -> Void
    ) {
        self.open = open
        self.reopenAfter = reopenAfter
        self.queue = queue
        self.log = log
    }

    /// For a simulator on iOS 27 or later, whose every read otherwise opens and drops a session of its own.
    static func live(simulator: FBSimulator, logger: OffsiderLogger, log: @escaping @Sendable (String) -> Void) -> BrokerAccessibilityHold? {
        guard simulator.osVersion.version.majorVersion >= 27 else { return nil }
        let device: AnyObject = simulator.device
        nonisolated(unsafe) let unsafeDevice = device
        nonisolated(unsafe) let unsafeLogger = logger
        return BrokerAccessibilityHold(open: {
            do {
                return try FBSimulatorControlFrameworkLoader.holdAccessibility(forSimulatorDevice: unsafeDevice, timeout: 5, logger: unsafeLogger)
            } catch {
                log("Could not hold the simulator's accessibility session: \(error.localizedDescription)")
                return nil
            }
        }, log: log)
    }

    /// Starts opening the session unless one is open, opening or was tried within `reopenInterval`.
    func start() {
        lock.lock()
        let now = ContinuousClock.now
        guard !closed, session == nil, !opening, lastTry.map({ now - $0 >= reopenAfter }) ?? true else {
            lock.unlock()
            return
        }
        opening = true
        lastTry = now
        lock.unlock()
        queue.async { [self] in
            let opened = open()
            lock.lock()
            opening = false
            let keep = !closed
            if keep {
                session = opened
                token = opened.map { _ in String(UInt64.random(in: 1...UInt64.max), radix: 36) }
            }
            lock.unlock()
            if !keep { opened?.invalidate() }
            if keep, opened != nil { log("Holding the simulator's accessibility session") }
        }
    }

    /// Whether a live session is open now; a dead one is dropped and, with `reopening`, opened again in the background.
    func isHeld(reopening: Bool = true) -> Bool {
        heldToken(reopening: reopening) != nil
    }

    /// The open session's name while it is live; nil once it has ended.
    func heldToken(reopening: Bool = true) -> String? {
        lock.lock()
        let current = session
        let valid = current?.isValid == true
        if current != nil, !valid {
            session = nil
            token = nil
        }
        let name = valid ? token : nil
        lock.unlock()
        if current != nil, !valid {
            current?.invalidate()
            log("The simulator's accessibility session ended")
        }
        if !valid, reopening { start() }
        return name
    }

    /// Ends the session for good; one still opening is ended as it arrives, and the process exiting ends it too.
    func close() {
        lock.lock()
        closed = true
        let current = session
        session = nil
        token = nil
        lock.unlock()
        current?.invalidate()
        if current != nil { log("Released the simulator's accessibility session") }
    }
}

/// A command's use of its broker's session: reads skip idb's per-request bootstrap only while the broker answers that one is open.
@MainActor
enum AccessibilityHold {
    /// How long a command waits for the broker's answer before reading as it would with no broker.
    nonisolated static let askMilliseconds = 500
    private static var asked: Set<String> = []
    /// The session each simulator's broker named when this command asked; reads trust it only while the broker still names it.
    private static var trusted: [String: String] = [:]

    /// Asks the simulator's broker once per command; on iOS 27 or later, with the warm session on, a yes lets this command's reads skip the bootstrap.
    static func adopt(_ simulator: FBSimulator, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        let udid = simulator.udid
        guard asked.insert(udid).inserted, simulator.osVersion.version.majorVersion >= 27,
              (try? SimulatorSessionSettings.isWarm(environment)) == true else { return }
        let token = await Timings.measure("accessibility-hold") {
            await HIDBroker.offMain { ask(simulatorUDID: udid) }
        }
        if let token { trust(udid: udid, token: token) }
    }

    static func trust(udid: String, token: String) {
        trusted[udid] = token
        FBSimulatorControlFrameworkLoader.setAccessibilityHeld(true, forSimulatorUDID: udid)
    }

    /// Runs a read; when it trusted the hold and the broker no longer names the same live session afterwards, the read may have missed what started while none was open, so it runs again with a bootstrap. A read that stopped trusting it on its own has already bootstrapped its later tries.
    static func reading<T>(udid: String, confirm: (String) async -> String? = { udid in await HIDBroker.offMain { ask(simulatorUDID: udid) } }, _ read: () async throws -> T) async throws -> T {
        guard let token = trusted[udid] else { return try await read() }
        let value = try await read()
        guard trusted[udid] == token else { return value }
        if await confirm(udid) == token { return value }
        stopTrusting(udid: udid)
        return try await read()
    }

    /// A read that came back empty while trusting the hold: the hold may have ended, so every later read in this command bootstraps.
    static func readCameBackEmpty(udid: String) {
        stopTrusting(udid: udid)
    }

    private static func stopTrusting(udid: String) {
        guard trusted.removeValue(forKey: udid) != nil else { return }
        FBSimulatorControlFrameworkLoader.setAccessibilityHeld(false, forSimulatorUDID: udid)
        Timings.record("accessibility-unheld", seconds: 0)
    }

    static func isTrusted(udid: String) -> Bool {
        trusted[udid] != nil
    }

    /// One `accessibility` request to a running broker, answered with the live session's name: no broker started, none replaced, and any failure is nil.
    nonisolated static func ask(simulatorUDID: String) -> String? {
        guard let endpoint = try? HIDBroker.endpointPath(simulatorUDID: simulatorUDID), HIDBroker.liveness(endpoint: endpoint) == .alive else { return nil }
        return ask(endpoint: endpoint)
    }

    nonisolated static func ask(endpoint: String, connector: (String) throws -> Int32 = HIDBroker.connect(to:)) -> String? {
        guard var request = try? JSONEncoder().encode(HIDBrokerRequest(op: .accessibility)),
              let descriptor = try? connector(endpoint) else { return nil }
        defer { Darwin.close(descriptor) }
        request.append(0x0A)
        guard (try? HIDBroker.configureReceiveTimeout(descriptor, milliseconds: askMilliseconds)) != nil,
              let handshake = try? HIDBroker.readMessage(from: descriptor, withinMilliseconds: askMilliseconds),
              (try? JSONDecoder().decode(HIDBrokerHandshake.self, from: handshake))?.ready == true,
              let reply = try? HIDBroker.exchange(request, on: descriptor, timeoutMilliseconds: askMilliseconds),
              reply.accessibilityHeld == true else { return nil }
        return reply.accessibilitySession
    }
}
