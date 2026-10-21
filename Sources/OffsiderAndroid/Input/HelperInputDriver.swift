import Foundation
import OffsiderCore

/// Input through the running helper's `inject`; the helper keeps fingers and keys held across requests.
@MainActor
final class HelperInputDriver {
    let session: HelperSession
    /// Modifiers held down so far in this command, for the meta state of later keys.
    private var held: Set<UInt32> = []
    /// The last inject failed with `inject-refused` or `inject-failed`, after which the helper has cancelled every finger and key.
    private(set) var releasedInput = false
    /// The host's clock, for the round trip between requests.
    private let uptime: @Sendable () -> Duration

    init(session: HelperSession, uptime: @escaping @Sendable () -> Duration) {
        self.session = session
        self.uptime = uptime
    }

    var serial: String { session.serial }

    func run(_ steps: [AndroidInputStep]) async throws {
        var held = self.held
        let requests = try HelperInjectPlan.requests(for: steps, held: &held)
        do {
            try await send(requests)
        } catch {
            // The helper lets go of every held key when an inject fails.
            self.held = []
            throw error
        }
        self.held = held
    }

    func type(_ chunks: [AndroidTextPlan.Chunk]) async throws {
        try await send(try HelperInjectPlan.requests(for: chunks))
    }

    /// Lifts a finger left down, as the last step of a session that failed part-way.
    func lift(at point: AndroidPoint) async throws {
        try await run([.touch(.up, point)])
    }

    /// Each request's round trip, its time here less the helper's own, comes off the pause that opens the next one, so a gesture split across requests keeps its timing.
    private func send(_ requests: [HelperInjectPlan.Request]) async throws {
        releasedInput = false
        var roundTrip = 0
        for var request in requests {
            request.shortenLeadingPause(by: roundTrip)
            let started = uptime()
            do {
                let reply = try await session.inject(request.steps, sync: request.sync, extraWait: .milliseconds(request.deviceMilliseconds))
                roundTrip = max(0, Int((uptime() - started) / .milliseconds(1)) - reply.totalMs)
            } catch let error as HelperErrorBody {
                releasedInput = error.code == "inject-refused" || error.code == "inject-failed"
                throw AndroidError.inputFailed(serial: serial, detail: "the UiAutomation helper reported \(error.code): \(error.message)")
            } catch let error as HelperProtocolError {
                throw AndroidError.inputFailed(serial: serial, detail: "the UiAutomation helper failed (\(error.detail))")
            } catch HelperStartFailure.busy {
                throw AndroidError.helperBusy(serial)
            }
        }
    }
}
