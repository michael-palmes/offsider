import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Input --json")
@MainActor
struct InputJSONTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func object(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    /// Runs `body` as an input command under `--json` or not, on a console that records both streams and a fresh dispatch tracker.
    static func reporting(json: Bool, _ body: @escaping @MainActor (InputDetails) async throws -> Void) async -> (capture: ConsoleCapture, error: (any Error)?) {
        let capture = ConsoleCapture()
        var thrown: (any Error)?
        await DispatchTracker.$current.withValue(DispatchTracker()) {
            await Console.$current.withValue(capture.console(out: .agent, err: .agent)) {
                do {
                    try await InputOutput.reporting(command: "tap", target: "id=save", json: json, scope: CommandScope(), body)
                } catch {
                    thrown = error
                }
            }
        }
        return (capture, thrown)
    }

    @Test("a sent input's line reports ok, what it went to, that it was dispatched and its point, keys in order")
    func successLine() throws {
        let line = InputReport(command: "tap", target: "id=save", dispatched: .yes, point: UIPoint(x: 120.004, y: 640.5), elapsed: 0.0424).jsonLine()
        #expect(line == #"{"version":1,"ok":true,"command":"tap","target":"id=save","dispatched":"yes","point":{"x":120,"y":640.5},"elapsedMs":42,"exitCode":0,"error":null}"#)
    }

    @Test("a slider's line names the percent reached and its value, which the app wrote and so is untrusted")
    func sliderLine() throws {
        let json = try Self.object(InputReport(command: "slider", target: "id=volume", dispatched: .yes, percent: 40, value: "40%").jsonLine())
        #expect(json["percent"] as? Double == 40)
        #expect(json["value"] as? String == "40%")
        #expect(json["untrusted"] as? [String] == ["value"])
    }

    @Test("with --json, stdout is one report line and the command's own lines move to stderr")
    func jsonMovesLinesToStderr() async throws {
        let (capture, error) = await Self.reporting(json: true) { details in
            try await DispatchTracker.current.sending {}
            details.point = UIPoint(x: 10, y: 20)
            Console.current.show(InputPersonView.receipt("Tapped id=save", agent: "✓ Tap on id=save at (10, 20) completed successfully\n"))
        }
        #expect(error == nil)
        let lines = capture.out.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 1)
        let json = try Self.object(String(lines[0]))
        #expect(json["ok"] as? Bool == true && json["dispatched"] as? String == "yes" && json["exitCode"] as? Int == 0)
        #expect(json["point"] as? [String: Double] == ["x": 10, "y": 20])
        #expect(capture.err == "✓ Tap on id=save at (10, 20) completed successfully\n")
    }

    @Test("without --json the command prints as it always did, and no report")
    func plainOutputUnchanged() async throws {
        let (capture, error) = await Self.reporting(json: false) { _ in
            Console.current.show(InputPersonView.receipt("Tapped id=save", agent: "✓ Tap on id=save completed successfully\n"))
        }
        #expect(error == nil)
        #expect(capture.out == "✓ Tap on id=save completed successfully\n")
        #expect(capture.err.isEmpty)
    }

    @Test("a send that fails part way prints the report with dispatched unknown and its error, then exits with the error's code")
    func failureAfterSend() async throws {
        let (capture, error) = await Self.reporting(json: true) { _ in
            try await DispatchTracker.current.sending {
                throw CLIError(errorDescription: "The device stopped answering.", reason: .deviceUnresponsive)
            }
        }
        let reported = try #require(error as? ReportedFailure)
        #expect(reported.exitCode == FailureReason.deviceUnresponsive.exitCode)
        let json = try Self.object(capture.out.trimmingCharacters(in: .newlines))
        #expect(json["ok"] as? Bool == false && json["dispatched"] as? String == "unknown")
        #expect(json["exitCode"] as? Int == Int(FailureReason.deviceUnresponsive.exitCode.rawValue))
        let payload = try #require(json["error"] as? [String: Any])
        #expect(payload["reason"] as? String == "device_unresponsive" && payload["dispatched"] as? String == "unknown")
    }

    @Test("a selector tap tells its report the point it resolved the element to")
    func tapResolvesPoint() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 600, 100, 40)),
        ])])
        let details = InputDetails()
        try await DispatchTracker.$current.withValue(DispatchTracker()) {
            try await Tap.parse(["--id", "save", "--no-settle", "--json", "--device", Self.device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger(), details: details)
        }
        #expect(details.point == UIPoint(x: 70, y: 620))
    }

    @Test("tap, type, key and button take --json without --verify; --verify-timeout and --retries still need it")
    func jsonNeedsNoVerify() throws {
        _ = try Tap.parse(["-x", "1", "-y", "1", "--json", "--device", Self.device.rawValue])
        _ = try Type.parse(["hello", "--json", "--device", Self.device.rawValue])
        _ = try Key.parse(["40", "--json", "--device", Self.device.rawValue])
        _ = try Button.parse(["home", "--json", "--device", Self.device.rawValue])
        #expect(throws: (any Error).self) { try Tap.parse(["-x", "1", "-y", "1", "--retries", "1", "--device", Self.device.rawValue]) }
    }

    @Test("a key combo's target names its keycodes, modifiers first")
    func keyComboTarget() {
        #expect(KeyCombo.target(modifiers: [227, 225], key: 4) == "keycodes 227+225+4")
    }
}

@Suite("Input --json from the command line")
struct InputJSONCommandLineTests {
    static let commands: [(line: String, command: String, target: String)] = [
        ("tap -x 5 -y 6", "tap", "(5, 6)"),
        ("tap --id save", "tap", "id=save"),
        ("type S3NT1NEL", "type", "text"),
        ("key 40", "key", "keycode 40"),
        ("key-sequence --keycodes 22,8,6", "key-sequence", "keys"),
        ("key-combo --modifiers 227 --key 4", "key-combo", "keycodes 227+4"),
        ("button home", "button", "home"),
        ("swipe --start-x 10 --start-y 600 --end-x 10 --end-y 200", "swipe", "(10, 600) to (10, 200)"),
        ("drag --start-x 10 --start-y 300 --end-x 10 --end-y 600", "drag", "(10, 300) to (10, 600)"),
        ("touch -x 100 -y 200 --down --up", "touch", "(100, 200)"),
        ("gesture scroll-up", "gesture", "scroll-up"),
        ("slider --id volume --value 40", "slider", "id=volume"),
        ("shake", "shake", "shake"),
    ]

    @Test("every input command's --json prints one report on stdout, nothing dispatched, when the device is missing", arguments: commands.indices)
    func missingDevice(index: Int) async throws {
        let (line, command, target) = Self.commands[index]
        let udid = TestDevices.simulatorUDID()
        defer { TestDevices.removePrivateFiles(platform: .ios, id: udid) }
        let result = try await TestHelpers.runOffsiderCommandSeparated("\(line) --json --device \(udid)")
        #expect(result.exitCode == 7)
        let lines = result.stdout.split(separator: "\n")
        try #require(lines.count == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(json["version"] as? Int == 1 && json["ok"] as? Bool == false)
        #expect(json["command"] as? String == command && json["target"] as? String == target)
        #expect(json["dispatched"] as? String == "no" && json["exitCode"] as? Int == 7)
        #expect((json["error"] as? [String: Any])?["reason"] as? String == "device_not_found")
        #expect(result.stderr.hasPrefix("Error: ") && result.stderr.contains(udid))
        #expect(!result.stdout.contains("S3NT1NEL") && !result.stderr.contains("S3NT1NEL"))
    }
}
