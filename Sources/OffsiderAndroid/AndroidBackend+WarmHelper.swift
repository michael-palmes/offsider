import Foundation
import OffsiderCore

/// One device's warm helper, as `session status` shows it.
public struct WarmHelperStatus: Equatable, Sendable {
    public let serial: String
    /// `starting`, `ready` or `stopping`.
    public let state: String
    public let brokerPid: Int32
    public let helperPid: Int32?
    public let startedAt: Date
    public let idleSeconds: Int
    /// Seconds since the last command used it.
    public let idleFor: Int
}

/// The detached broker `android-session serve` runs for one serial.
@MainActor
public final class WarmHelperBroker {
    private let broker: HelperBroker

    init(_ broker: HelperBroker) {
        self.broker = broker
    }

    public func requestStop() {
        broker.requestStop()
    }

    /// Serves until idle, `stop`, a lost helper or 12 hours; throws only when it cannot listen.
    public func run() async throws {
        try await broker.run()
    }
}

extension AndroidBackend {
    /// The broker that keeps `serial`'s helper warm; the hidden `android-session serve` entry point runs it.
    /// `admits` decides, per connection, whether a same-user peer may use the broker.
    public func warmHelperBroker(for serial: String, admits: @escaping @Sendable (Int32) -> Bool) async throws -> WarmHelperBroker {
        guard let brokerHost = host.helperBroker else {
            throw AndroidError(.invalidSetting, "This host cannot keep a helper warm.")
        }
        try await prepare()
        let dex: HelperDex
        do {
            dex = try host.helperDex()
        } catch let error as HelperDexError {
            throw AndroidError(.helperUnavailable, "The UiAutomation helper cannot start: \(HelperUnavailableReason(error)).")
        }
        let client = try requireClient()
        let paths = HelperBrokerPaths(serial: serial, directory: try brokerHost.directory())
        let limits = HelperBroker.Limits(idle: .seconds(HelperBrokerSettings.idleSeconds(host.environment)))
        let log = self.log
        let timing = host.timing
        let broker = HelperBroker(
            serial: serial, socketPath: paths.socket, dexSha256: dex.sha256, limits: limits,
            startHelper: {
                try await HelperSession.start(
                    client: client, serial: serial, dex: dex, log: log, timing: timing, idleTimeoutMs: HelperBrokerSettings.helperIdleTimeoutMs
                )
            },
            admits: admits,
            log: log
        )
        return WarmHelperBroker(broker)
    }

    /// Every answering warm helper, or `serial`'s alone; never starts one and never counts as use.
    public static func warmHelpers(host: AndroidHost, serial: String? = nil) async -> [WarmHelperStatus] {
        var found: [WarmHelperStatus] = []
        for socket in host.warmHelperSockets(serial: serial) {
            guard let status = await HelperBrokerClient.status(at: socket) else { continue }
            found.append(WarmHelperStatus(
                serial: status.serial, state: status.state.rawValue, brokerPid: status.brokerPid, helperPid: status.helperPid,
                startedAt: Date(timeIntervalSince1970: status.startedAt), idleSeconds: status.idleSeconds, idleFor: status.idleFor
            ))
        }
        return found
    }

    /// Stops every warm helper, or `serial`'s alone, another build's too, each once its UiAutomation slot is free; returns the serials stopped.
    /// A broker of another build refuses the request, so it is found by its arguments and the socket it holds, and signalled instead.
    public static func stopWarmHelpers(host: AndroidHost, serial: String? = nil) async -> [String] {
        var stopped: [String] = []
        for socket in host.warmHelperSockets(serial: serial) {
            var name = serial
            if name == nil {
                name = await HelperBrokerClient.servedSerial(at: socket)
            }
            if await HelperBrokerClient.stop(at: socket) {
                stopped.append(name ?? "unknown")
                continue
            }
            guard UnixSocket.answers(socket), let name, let requirement = try? PeerCodeIdentity.ownRequirement(),
                  !BrokerProcess.stopOtherBuilds(serving: HelperBrokerClient.serveArguments(name), boundTo: socket, requirement: requirement).stopped.isEmpty
            else {
                continue
            }
            await HelperBrokerClient.untilGone(socket)
            stopped.append(name)
        }
        return stopped
    }
}
