import Foundation

public struct DoctorCheckResult: Codable, Equatable, Sendable {
    public let id: DoctorCheckID
    public let title: String
    public let status: CheckStatus
    public let detail: String
    public let hint: String?
    public let fixable: Bool

    public init(id: DoctorCheckID, status: CheckStatus, detail: String, hint: String? = nil, fixable: Bool = false) {
        self.id = id
        self.title = id.title
        self.status = status
        self.detail = detail
        self.hint = hint
        self.fixable = fixable
    }

    public init(id: DoctorCheckID, verdict: DoctorRules.Verdict, fixable: Bool = false) {
        self.init(id: id, status: verdict.status, detail: verdict.detail, hint: verdict.hint, fixable: fixable)
    }

    public static func skipped(_ id: DoctorCheckID, _ reason: String) -> DoctorCheckResult {
        DoctorCheckResult(id: id, status: .skip, detail: reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(detail, forKey: .detail)
        try container.encode(hint, forKey: .hint)
        try container.encode(fixable, forKey: .fixable)
    }
}

public struct DoctorFixResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case applied
        case skipped
        case failed
    }

    public let id: DoctorCheckID
    public let action: String
    public let outcome: Outcome
    public let detail: String

    public init(id: DoctorCheckID, action: String, outcome: Outcome, detail: String) {
        self.id = id
        self.action = action
        self.outcome = outcome
        self.detail = detail
    }
}

public struct BootedSimulator: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let osVersion: String
    public let deviceType: String

    public init(udid: String, name: String, osVersion: String, deviceType: String) {
        self.udid = udid
        self.name = name
        self.osVersion = osVersion
        self.deviceType = deviceType
    }
}

public struct XcodeSummary: Codable, Equatable, Sendable {
    public let developerDir: String?
    public let version: String?
    public let build: String?
    public let coreSimulator: String?

    public init(developerDir: String?, version: String?, build: String?, coreSimulator: String?) {
        self.developerDir = developerDir
        self.version = version
        self.build = build
        self.coreSimulator = coreSimulator
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(developerDir, forKey: .developerDir)
        try container.encode(version, forKey: .version)
        try container.encode(build, forKey: .build)
        try container.encode(coreSimulator, forKey: .coreSimulator)
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let offsiderVersion: String
    public let udid: String?
    public let xcode: XcodeSummary
    public let booted: [BootedSimulator]
    public let checks: [DoctorCheckResult]
    public let fixes: [DoctorFixResult]

    public init(
        offsiderVersion: String,
        udid: String?,
        xcode: XcodeSummary,
        booted: [BootedSimulator],
        checks: [DoctorCheckResult],
        fixes: [DoctorFixResult] = []
    ) {
        self.version = Self.schemaVersion
        self.offsiderVersion = offsiderVersion
        self.udid = udid
        self.xcode = xcode
        self.booted = booted
        self.checks = checks
        self.fixes = fixes
    }

    public var status: CheckStatus {
        CheckStatus.aggregate(checks.map(\.status))
    }

    public var exitCode: OffsiderExitCode {
        switch status {
        case .pass, .skip: return .success
        case .warn: return .doctorWarnings
        case .fail: return .doctorFailures
        }
    }

    public func check(_ id: DoctorCheckID) -> DoctorCheckResult? {
        checks.first { $0.id == id }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case version, offsiderVersion, udid, xcode, booted, checks, fixes
    }

    private enum EncodingKeys: String, CodingKey {
        case version, offsiderVersion, status, udid, xcode, booted, checks, fixes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EncodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(offsiderVersion, forKey: .offsiderVersion)
        try container.encode(status, forKey: .status)
        try container.encode(udid, forKey: .udid)
        try container.encode(xcode, forKey: .xcode)
        try container.encode(booted, forKey: .booted)
        try container.encode(checks, forKey: .checks)
        try container.encode(fixes, forKey: .fixes)
    }
}
