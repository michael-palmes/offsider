import Foundation
import OffsiderCore
import Testing

@Suite("Failure reasons")
struct FailureReasonTests {
    @Test("every reason maps to a documented exit code that is not success or a doctor code")
    func reasonsMapToCodes() {
        for reason in FailureReason.allCases {
            #expect(OffsiderExitCode.allCases.contains(reason.exitCode))
            #expect(![OffsiderExitCode.success, .doctorWarnings, .doctorFailures].contains(reason.exitCode), "\(reason)")
        }
    }

    @Test("reasons are lower snake_case and unique")
    func reasonsAreSnakeCase() {
        let names = FailureReason.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.range(of: "^[a-z]+(_[a-z]+)*$", options: .regularExpression) != nil, "\(name)")
        }
    }

    @Test("the error envelope has version, ok, command, exitCode and error, in that order")
    func envelopeShape() throws {
        let envelope = ErrorEnvelope(
            command: "screenshot",
            error: ErrorPayload(reason: .deviceNotFound, message: "No device", hint: "offsider list-devices")
        )
        let line = envelope.jsonLine()
        #expect(line.hasPrefix(#"{"version":1,"ok":false,"command":"screenshot","exitCode":7,"error":{"reason":"device_not_found","message":"No device","hint":"offsider list-devices","dispatched":null,"candidates":[]}}"#))
    }

    @Test("a payload keeps at most five candidates")
    func payloadCapsCandidates() {
        let candidate = FailureCandidate(id: "a", label: nil, role: "button", frame: nil, onScreen: nil)
        #expect(ErrorPayload(reason: .selectorAmbiguous, message: "m", candidates: Array(repeating: candidate, count: 8)).candidates.count == 5)
    }
}
