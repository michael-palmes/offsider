import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Coordinate limits")
@MainActor
struct CoordinatesTests {
    static let outside = ["inf", "nan", "1e19", "-1e19", "100001", "-100001"]
    static let limitText = "from -100000 to 100000"

    private static func usageMessage<C: ParsableCommand>(_ type: C.Type, _ arguments: [String]) -> (code: Int32, message: String)? {
        do {
            _ = try type.parse(arguments + ["--device", "emulator-5554"])
            return nil
        } catch {
            return (type.exitCode(for: error).rawValue, type.message(for: error))
        }
    }

    @Test("the shared check refuses what is not finite or past the helper's limit, naming the limit", arguments: [Double.infinity, -.infinity, .nan, 1e19, -1e19, 100_001, -100_000.5])
    func sharedCheckRefuses(value: Double) {
        let problem = Coordinates.problem([("-x", 1), ("-y", value)])
        #expect(problem?.hasPrefix("-y must be a number \(Self.limitText); got ") == true)
    }

    @Test("the limit itself and ordinary values pass; a missing optional is skipped")
    func sharedCheckPasses() {
        #expect(Coordinates.problem([("-x", 100_000), ("-y", -100_000), ("--delta", nil), ("--spread", 0)]) == nil)
    }

    @Test("tap -x refuses each out-of-range value as a usage error naming the limit", arguments: outside)
    func tap(value: String) {
        let failure = Self.usageMessage(Tap.self, ["-x=\(value)", "-y", "10"]) ?? Self.usageMessage(Tap.self, ["-x", value, "-y", "10"])
        #expect(failure?.code == ExitCode.validationFailure.rawValue)
        #expect(failure?.message.contains(Self.limitText) == true)
    }

    @Test("swipe refuses each out-of-range coordinate and delta", arguments: outside)
    func swipe(value: String) {
        let coordinate = Self.usageMessage(Swipe.self, ["--start-x=\(value)", "--start-y", "800", "--end-x", "200", "--end-y", "400"])
        #expect(coordinate?.code == ExitCode.validationFailure.rawValue)
        #expect(coordinate?.message.contains("--start-x must be a number \(Self.limitText)") == true)
        guard value != "-1e19", value != "-100001" else { return }
        let delta = Self.usageMessage(Swipe.self, ["--start-x", "200", "--start-y", "800", "--end-x", "200", "--end-y", "400", "--delta=\(value)"])
        #expect(delta?.message.contains("--delta must be a number \(Self.limitText)") == true)
    }

    @Test("drag refuses each out-of-range coordinate", arguments: outside)
    func drag(value: String) {
        let failure = Self.usageMessage(Drag.self, ["--start-x", "10", "--start-y", "10", "--end-x", "10", "--end-y=\(value)"])
        #expect(failure?.code == ExitCode.validationFailure.rawValue)
        #expect(failure?.message.contains("--end-y must be a number \(Self.limitText)") == true)
    }

    @Test("touch refuses each out-of-range coordinate", arguments: outside)
    func touch(value: String) {
        let failure = Self.usageMessage(Touch.self, ["-x", "10", "-y=\(value)", "--down", "--up"]) ?? Self.usageMessage(Touch.self, ["-x", "10", "-y", value, "--down", "--up"])
        #expect(failure?.code == ExitCode.validationFailure.rawValue)
        #expect(failure?.message.contains(Self.limitText) == true)
    }

    @Test("gesture long-press-drag refuses each out-of-range point", arguments: outside)
    func gesture(value: String) {
        let failure = Self.usageMessage(Gesture.self, ["long-press-drag", "--x", "10", "--y", "10", "--to-x=\(value)", "--to-y", "10"])
        #expect(failure?.code == ExitCode.validationFailure.rawValue)
        #expect(failure?.message.contains("--to-x must be a number \(Self.limitText)") == true)
    }

    @Test("100000 is accepted by every command")
    func limitPasses() throws {
        _ = try Tap.parse(["-x", "100000", "-y", "10", "--device", "emulator-5554"])
        _ = try Swipe.parse(["--start-x", "100000", "--start-y", "800", "--end-x", "200", "--end-y", "400", "--delta", "100000", "--device", "emulator-5554"])
        _ = try Drag.parse(["--start-x", "10", "--start-y", "10", "--end-x", "10", "--end-y", "100000", "--device", "emulator-5554"])
        _ = try Touch.parse(["-x", "100000", "-y", "10", "--down", "--up", "--device", "emulator-5554"])
        _ = try Gesture.parse(["long-press-drag", "--x", "10", "--y", "10", "--to-x", "100000", "--to-y", "10", "--device", "emulator-5554"])
    }

    @Test("negative coordinates within the limit keep their own message")
    func negativeKeepsMessage() {
        let failure = Self.usageMessage(Tap.self, ["-x=-5", "-y", "10"])
        #expect(failure?.message.contains("Coordinates must be non-negative values.") == true)
    }

    @Test("a batch step is held to the same limit before anything is sent")
    func batchStep() async {
        let device = DeviceID(rawValue: "STUB", platform: .ios)
        let session = RecordingInputSession()
        let context = BatchContext(backend: StubBackend(session: session), device: device, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)
        let error = await #expect(throws: (any Error).self) {
            _ = try await BatchStepParser.parseStep(["tap", "-x", "1e19", "-y", "10"], deviceID: "STUB", context: context, logger: OffsiderLogger())
        }
        #expect(error.map { Tap.message(for: $0).contains(Self.limitText) } == true)
        #expect(error.map { Tap.exitCode(for: $0) } == .validationFailure)
    }
}
