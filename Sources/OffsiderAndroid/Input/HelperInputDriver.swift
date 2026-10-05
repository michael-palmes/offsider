import Foundation
import OffsiderCore

/// Input through the running helper's `inject`; the helper keeps fingers and keys held across requests.
@MainActor
final class HelperInputDriver {
    let session: HelperSession
    /// Modifiers held down so far in this command, for the meta state of later keys.
    private var held: Set<UInt32> = []

    init(session: HelperSession) {
        self.session = session
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

    private func send(_ requests: [HelperInjectPlan.Request]) async throws {
        for request in requests {
            do {
                _ = try await session.inject(request.steps, extraWait: .milliseconds(request.waitMilliseconds))
            } catch let error as HelperErrorBody {
                throw AndroidError.inputFailed(serial: serial, detail: "the UiAutomation helper reported \(error.code): \(error.message)")
            } catch let error as HelperProtocolError {
                throw AndroidError.inputFailed(serial: serial, detail: "the UiAutomation helper failed (\(error.detail))")
            } catch HelperStartFailure.busy {
                throw AndroidError.helperBusy(serial)
            }
        }
    }
}
