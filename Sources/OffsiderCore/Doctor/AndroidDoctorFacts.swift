import Foundation

/// What the Android doctor probe read; plain values so the verdicts stay pure.
public enum AndroidSDKFact: Equatable, Sendable {
    /// `source` is the variable name, `default location` or `adb on PATH`.
    case found(root: String, source: String, adbPath: String)
    case variableWithoutAdb(variable: String, message: String)
    case notFound
}

public enum AdbBinaryFact: Equatable, Sendable {
    /// `version` is the release with its revision, such as `37.0.0-14910828`; `protocolVersion` is 41 for `1.0.41`.
    case version(String, protocolVersion: Int?)
    case failed(String)
}

public enum AdbServerFact: Equatable, Sendable {
    case answering(endpoint: String, version: Int)
    case notRunning(endpoint: String)
    case noAnswer(endpoint: String, detail: String)
    /// `ADB_SERVER_SOCKET` or the port setting points off this Mac, or cannot be read.
    case badSetting(String)
}

public enum AdbMDNSFact: Equatable, Sendable {
    case disabled(String)
    case active(String)
    case unknown(String)
}

public enum HelperBundleFact: Equatable, Sendable {
    case ok(version: String, protocolVersion: Int)
    case problem(String)
}

/// One `host:devices-l` row; only the named device is queried, so others carry adb's state alone.
public struct AndroidDeviceRow: Codable, Equatable, Sendable {
    public let serial: String
    /// `emulator` for `emulator-<port>` serials, otherwise `other`.
    public let kind: String
    public let state: String
    public let avd: String?
    public let apiLevel: Int?

    public init(serial: String, kind: String, state: String, avd: String?, apiLevel: Int?) {
        self.serial = serial
        self.kind = kind
        self.state = state
        self.avd = avd
        self.apiLevel = apiLevel
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serial, forKey: .serial)
        try container.encode(kind, forKey: .kind)
        try container.encode(state, forKey: .state)
        try container.encode(avd, forKey: .avd)
        try container.encode(apiLevel, forKey: .apiLevel)
    }
}

public struct AndroidHostFacts: Equatable, Sendable {
    public var sdk: AndroidSDKFact
    public var adb: AdbBinaryFact?
    public var server: AdbServerFact?
    public var mdns: AdbMDNSFact?
    /// `Pkg.Revision` of the emulator package; nil when it is not installed.
    public var emulatorRevision: String?
    public var helperBundle: HelperBundleFact
    /// Nil when the server did not answer.
    public var devices: [AndroidDeviceRow]?

    public init(
        sdk: AndroidSDKFact,
        adb: AdbBinaryFact? = nil,
        server: AdbServerFact? = nil,
        mdns: AdbMDNSFact? = nil,
        emulatorRevision: String? = nil,
        helperBundle: HelperBundleFact,
        devices: [AndroidDeviceRow]? = nil
    ) {
        self.sdk = sdk
        self.adb = adb
        self.server = server
        self.mdns = mdns
        self.emulatorRevision = emulatorRevision
        self.helperBundle = helperBundle
        self.devices = devices
    }
}

public enum AndroidDeviceStateFact: Equatable, Sendable {
    case booted
    case booting
    case offline
    case unauthorised
    case other(String)
    case notFound(String)
}

public enum EmulatorGrpcFact: Equatable, Sendable {
    case forcedAdb
    case noDiscoveryFile(forced: Bool)
    case noGrpcPort(forced: Bool)
    /// `auth` is `token` or `jwt`, never the credential itself.
    case connected(endpoint: String, auth: String, statusMilliseconds: Int, booted: Bool)
    case failed(String, forced: Bool)
}

public struct UiAutomationFact: Equatable, Sendable {
    public let accessibilityEnabled: Bool?
    public let enabledServices: [String]
    public let offsiderHelperPids: [Int32]

    public init(accessibilityEnabled: Bool?, enabledServices: [String], offsiderHelperPids: [Int32]) {
        self.accessibilityEnabled = accessibilityEnabled
        self.enabledServices = enabledServices
        self.offsiderHelperPids = offsiderHelperPids
    }
}

public enum HelperProbeFact: Equatable, Sendable {
    case ready(launchMilliseconds: Int, pushed: Bool, helloMilliseconds: Int, pingMilliseconds: Int, protocolVersion: Int, sdkInt: Int)
    case busy(String)
    case unavailable(String)
    case forcedOff
}

public struct AndroidDeviceFacts: Equatable, Sendable {
    public var id: String
    public var serial: String?
    public var avdName: String?
    public var state: AndroidDeviceStateFact
    public var apiLevel: Int?
    public var release: String?
    public var abi: String?
    public var grpc: EmulatorGrpcFact?
    public var uiAutomation: UiAutomationFact?
    public var helper: HelperProbeFact?
    /// `reverse:list-forward` lines; nil when the list could not be read.
    public var reverses: [String]?
    /// A USB phone: its state comes from the device list, and emulator-only checks are skipped.
    public var isPhysical = false
    public var model: String?
    /// Screen, lock screen and stay awake; nil when they could not be read.
    public var awake: AwakeReading?
    /// `adb_allowed_connection_time` as read, where `null` is the 7-day default; phones only.
    public var adbAuthorisationTimeout: String?
    /// `ota_disable_automatic_update` as read, where `1` turns automatic system updates off; phones only.
    public var automaticUpdatesDisabled: String?

    public init(id: String, serial: String? = nil, avdName: String? = nil, state: AndroidDeviceStateFact) {
        self.id = id
        self.serial = serial
        self.avdName = avdName
        self.state = state
    }
}
