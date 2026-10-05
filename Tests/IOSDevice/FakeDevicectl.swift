import Foundation
import OffsiderCore
import OffsiderIOSDevice

enum IOSDeviceFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    static let phone = "00008130-0000000000000ABC"
    static let iPad = "0123456789abcdef0123456789abcdef01234567"

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

/// Scripted `devicectl` replies keyed by the subcommand (`list`, `details`, `ddiServices`, ...); records every call.
final class FakeDevicectl: DevicectlRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let xcode: Result<XcodeLocation, IOSDeviceError>
    private let replies: [String: ProcessCaptureResult]
    private let effect: (@Sendable ([String]) -> Void)?

    /// `effect` runs before each reply, as devicectl writing a file would.
    init(
        xcode: Result<XcodeLocation, IOSDeviceError> = .success(XcodeLocation(developerDirectory: "/Xcode.app/Contents/Developer", source: "xcode-select", version: "27.0", build: "27A266a")),
        replies: [String: ProcessCaptureResult],
        effect: (@Sendable ([String]) -> Void)? = nil
    ) {
        self.xcode = xcode
        self.replies = replies
        self.effect = effect
    }

    static func listing(_ fixture: String, extra: [String: ProcessCaptureResult] = [:]) throws -> FakeDevicectl {
        var replies = extra
        replies["list"] = ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text(fixture), stderr: "")
        return FakeDevicectl(replies: replies)
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func locateXcode() async throws -> XcodeLocation {
        try xcode.get()
    }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessCaptureResult {
        lock.withLock { recorded.append(arguments) }
        effect?(arguments)
        let key = arguments.first == "list" ? "list" : (arguments.count > 2 ? arguments[2] : arguments.joined(separator: " "))
        return replies[key] ?? ProcessCaptureResult(status: 0, stdout: "{\"info\": {\"outcome\": \"success\"}, \"result\": {}}", stderr: "")
    }
}

extension IOSDeviceHost {
    static func fake(
        _ devicectl: FakeDevicectl,
        environment: [String: String] = [:],
        existing: Set<String> = [],
        privateRoot: String = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-ios-tests-\(UUID().uuidString)").path,
        timing: IOSDeviceTiming = .disabled
    ) -> IOSDeviceHost {
        IOSDeviceHost(
            environment: environment,
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            devicectl: devicectl,
            fileExists: { existing.contains($0) },
            privateRoot: privateRoot,
            timing: timing
        )
    }
}
