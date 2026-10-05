import Foundation
import OffsiderCore

/// The selected Xcode, from `DEVELOPER_DIR` or `xcode-select -p`.
public struct XcodeLocation: Equatable, Sendable {
    public let developerDirectory: String
    public let source: String
    public let version: String?
    public let build: String?

    public init(developerDirectory: String, source: String, version: String?, build: String?) {
        self.developerDirectory = developerDirectory
        self.source = source
        self.version = version
        self.build = build
    }

    public var major: Int? {
        version.flatMap { $0.split(separator: ".").first.flatMap { Int($0) } }
    }
}

/// Runs `xcrun devicectl`; a protocol so tests never reach a device.
public protocol DevicectlRunning: Sendable {
    func locateXcode() async throws -> XcodeLocation
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessCaptureResult
}

/// `xcrun devicectl` with the resolved Xcode pinned through `DEVELOPER_DIR`.
public struct XcrunDevicectl: DevicectlRunning {
    let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    public func locateXcode() async throws -> XcodeLocation {
        let path: String
        let source: String
        if let variable = environment["DEVELOPER_DIR"], !variable.isEmpty {
            path = variable
            source = "DEVELOPER_DIR"
        } else {
            let result = try await ProcessCapture.run(executable: "/usr/bin/xcode-select", arguments: ["-p"], environment: environment, timeout: 5)
            path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            source = "xcode-select"
            guard result.status == 0, !path.isEmpty else {
                throw IOSDeviceError.xcodeMissing("xcode-select -p found no developer directory")
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IOSDeviceError.xcodeMissing("\(path) (from \(source)) does not exist")
        }
        let plist = NSDictionary(contentsOf: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("version.plist"))
        return XcodeLocation(
            developerDirectory: path,
            source: source,
            version: plist?["CFBundleShortVersionString"] as? String,
            build: plist?["ProductBuildVersion"] as? String
        )
    }

    public func run(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessCaptureResult {
        let xcode = try await locateXcode()
        var environment = environment
        environment["DEVELOPER_DIR"] = xcode.developerDirectory
        return try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: ["devicectl"] + arguments, environment: environment, timeout: timeout)
    }
}

/// Everything the iOS device backend reaches outside the process; tests replace each part.
public struct IOSDeviceHost: Sendable {
    public var environment: [String: String]
    public var homeDirectory: URL
    public var devicectl: any DevicectlRunning
    public var fileExists: @Sendable (String) -> Bool

    public init(
        environment: [String: String],
        homeDirectory: URL,
        devicectl: any DevicectlRunning,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.devicectl = devicectl
        self.fileExists = fileExists
    }

    public static func live() -> IOSDeviceHost {
        let environment = ProcessInfo.processInfo.environment
        return IOSDeviceHost(
            environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            devicectl: XcrunDevicectl(environment: environment)
        )
    }
}
