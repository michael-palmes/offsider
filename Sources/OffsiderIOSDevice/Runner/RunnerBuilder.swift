import CryptoKit
import Darwin
import Foundation
import OffsiderCore

/// A built runner: the `.xctestrun` that `test-without-building` starts, and the key its session must report.
public struct RunnerBuild: Equatable, Sendable {
    public let key: String
    public let xctestrun: URL
    public let directory: URL

    public init(key: String, xctestrun: URL, directory: URL) {
        self.key = key
        self.xctestrun = xctestrun
        self.directory = directory
    }
}

public enum RunnerDestination: Equatable, Sendable {
    case device(udid: String)
    case simulator(udid: String)

    public var udid: String {
        switch self {
        case .device(let udid), .simulator(let udid): return udid
        }
    }
}

/// Builds the runner or returns the cached build; a protocol so tests never run xcodebuild.
public protocol RunnerBuilding: Sendable {
    func build(for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild
    /// Checks a build's products before they are installed, rebuilding once when they changed; called only when a session starts.
    func verifyForLaunch(_ build: RunnerBuild, for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild
}

extension RunnerBuilding {
    public func verifyForLaunch(_ build: RunnerBuild, for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild {
        build
    }
}

/// Runs `xcrun xcodebuild` with these arguments, environment and timeout; tests replace it.
public typealias XcodebuildRunning = @Sendable (_ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) async throws -> ProcessCaptureResult

/// The first device build under a new `OFFSIDER_IOS_RUNNER_PREFIX` outside `runner build`: only a person approves a prefix.
public struct RunnerPrefixNeedsPerson: OffsiderFailure, LocalizedError, Equatable, Sendable {
    public let prefix: String
    public let udid: String

    public var reason: FailureReason { .personRequired }
    public var failureMessage: String {
        "\(XcodeRunnerBuilder.prefixVariable) names \(prefix), a bundle prefix this Mac has not built the runner under, and that first build creates App IDs in your team, so a person confirms it once. Nothing was built. Run `\(command)` in your own terminal."
    }
    public var hint: String? { command }
    public var errorDescription: String? { failureMessage }
    private var command: String { "offsider runner build --device \(udid)" }
}

/// Carries a refusal from the prefix approval past the build's catch-all, unchanged.
struct PrefixApproval: Error {
    let underlying: any Error
}

/// `xcodebuild build-for-testing` from the bundled source into `~/Library/Caches/offsider/runner/<key>/`.
public struct XcodeRunnerBuilder: RunnerBuilding {
    public static let teamVariable = "OFFSIDER_IOS_TEAM_ID"
    public static let prefixVariable = "OFFSIDER_IOS_RUNNER_PREFIX"
    public static let defaultPrefix = "com.mpalmes.offsider"
    static let maxPrefixLength = 100
    static let buildTimeout: TimeInterval = 300
    static let logTailLines = 20

    let source: URL
    let cacheRoot: URL
    let xcode: XcodeLocation
    let environment: [String: String]
    let signedInTeams: @Sendable () -> [String]
    let notice: @Sendable (String) -> Void
    /// The team `devices add --team` recorded for this device.
    let allowanceTeam: String?
    /// The runner source's digests compiled into this binary, keyed by path below `runner/`; nil hashes the source folder instead.
    let expectedSource: [String: String]?
    /// Lets xcodebuild register the device with the team; only `runner build --register-device` sets it.
    let registerDevice: Bool
    let xcodebuild: XcodebuildRunning
    /// Whether the bundle at a path is validly signed and satisfies a requirement, sealed resources included.
    let signatureValid: @Sendable (_ path: String, _ requirement: String) -> Bool

    public init(
        source: URL,
        cacheRoot: URL,
        xcode: XcodeLocation,
        environment: [String: String],
        signedInTeams: @escaping @Sendable () -> [String],
        notice: @escaping @Sendable (String) -> Void,
        allowanceTeam: String? = nil,
        expectedSource: [String: String]? = nil,
        registerDevice: Bool = false,
        xcodebuild: @escaping XcodebuildRunning = XcodeRunnerBuilder.runXcodebuild,
        signatureValid: @escaping @Sendable (String, String) -> Bool = { CodeSignatureCheck.satisfies(path: $0, requirement: $1, resources: true) }
    ) {
        self.source = source
        self.cacheRoot = cacheRoot
        self.xcode = xcode
        self.environment = environment
        self.signedInTeams = signedInTeams
        self.notice = notice
        self.allowanceTeam = allowanceTeam
        self.expectedSource = expectedSource
        self.registerDevice = registerDevice
        self.xcodebuild = xcodebuild
        self.signatureValid = signatureValid
    }

    public static let runXcodebuild: XcodebuildRunning = { arguments, environment, timeout in
        try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: ["xcodebuild"] + arguments, environment: environment, timeout: timeout)
    }

    public static func defaultCacheRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/offsider/runner", isDirectory: true)
    }

    /// The team the device's allowance names, else `OFFSIDER_IOS_TEAM_ID`; a variable naming another team than the person chose is refused. Never a team picked from Xcode's accounts.
    public static func resolveTeam(environment: [String: String], allowanceTeam: String?, signedInTeams: [String], audience: ErrorAudience = .current) throws -> String {
        if let team = environment[teamVariable]?.trimmingCharacters(in: .whitespaces), !team.isEmpty {
            guard DeviceAllowance.isTeamID(team) else {
                throw IOSDeviceError(.teamMissing, "\(teamVariable) must be a 10-character team ID such as ABCDE12345, not \(team).")
            }
            if let allowanceTeam, DeviceAllowance.isTeamID(allowanceTeam), allowanceTeam.caseInsensitiveCompare(team) != .orderedSame {
                throw IOSDeviceError(
                    .invalidSetting,
                    "\(teamVariable) is \(team), but this device's allowance names team \(allowanceTeam), and the team a person chose wins. Unset \(teamVariable), or choose that team again in `offsider devices add`.",
                    hint: "offsider devices add"
                )
            }
            return team
        }
        if let allowanceTeam, DeviceAllowance.isTeamID(allowanceTeam) { return allowanceTeam }
        let count = Set(signedInTeams).count
        throw IOSDeviceError(
            .teamMissing,
            "No Apple development team is chosen to sign the runner app (Xcode is signed in to \(count) \(count == 1 ? "team" : "teams"), and Offsider never picks one)."
                + audience.personStep("offsider devices add", agentTail: " and choose a team in its menu, or set \(teamVariable) to the team's ID"),
            hint: "offsider devices add"
        )
    }

    /// `OFFSIDER_IOS_RUNNER_PREFIX`, else `com.mpalmes.offsider`; the runner's bundle ids are `<prefix>.runner` and `<prefix>.runner.uitests`.
    public static func resolvePrefix(environment: [String: String]) throws -> String {
        guard let value = environment[prefixVariable]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return defaultPrefix }
        guard isBundlePrefix(value) else {
            throw IOSDeviceError(
                .invalidSetting,
                "\(prefixVariable) must be a reverse-DNS bundle id prefix of at most \(maxPrefixLength) characters, such as com.example.offsider, not \(value)."
            )
        }
        return value
    }

    static func isBundlePrefix(_ text: String) -> Bool {
        guard text.count <= maxPrefixLength, let pattern = try? Regex("^[A-Za-z][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)+$") else { return false }
        return text.allSatisfy(\.isASCII) && (try? pattern.wholeMatch(in: text)) != nil
    }

    /// The two apps a build installs: the UI test runner and its host.
    public static func installedBundleIDs(prefix: String) -> [String] {
        ["\(prefix).runner.uitests.xctrunner", "\(prefix).runner"]
    }

    /// sha256 over the source digest, Xcode's build, the team, the bundle prefix and the destination.
    public static func key(sourceDigest: String, xcodeBuild: String?, team: String?, prefix: String = defaultPrefix, destination: RunnerDestination) -> String {
        let destinationText: String
        switch destination {
        case .device(let udid): destinationText = "iphoneos \(udid)"
        case .simulator: destinationText = "iphonesimulator"
        }
        let text = [sourceDigest, xcodeBuild ?? "unknown", team ?? "", prefix, destinationText].joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One digest over `path\0digest\0` for each file, in path order.
    public static func sourceDigest(files: [String: String]) -> String {
        var hasher = SHA256()
        for path in files.keys.sorted() {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(files[path, default: ""].utf8))
            hasher.update(data: Data([0]))
        }
        return hex(hasher.finalize())
    }

    public static func sourceDigest(of directory: URL) throws -> String {
        sourceDigest(files: try fileDigests(in: directory))
    }

    /// sha256 of each source file, keyed by its relative path.
    static func fileDigests(in directory: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for path in try sourceFiles(in: directory) {
            digests[path] = hex(SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent(path))))
        }
        return digests
    }

    /// Relative paths, sorted, leaving out Xcode's per-user state.
    static func sourceFiles(in directory: URL) throws -> [String] {
        let base = directory.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw IOSDeviceError(.runnerBuildFailed, "The runner source at \(directory.path) is missing. Reinstall Offsider.")
        }
        var paths: [String] = []
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if relative.contains("xcuserdata") || url.lastPathComponent == ".DS_Store" { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { paths.append(relative) }
        }
        return paths.sorted()
    }

    /// Deletes Xcode's per-user state and Finder's `.DS_Store` from the copy: the digests leave them out, so they never reach xcodebuild.
    static func scrubCopiedSource(_ project: URL) throws {
        guard let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil) else { return }
        var unverified: [URL] = []
        for case let url as URL in walker {
            if url.lastPathComponent == "xcuserdata" {
                unverified.append(url)
                walker.skipDescendants()
            } else if url.lastPathComponent == ".DS_Store" {
                unverified.append(url)
            }
        }
        for url in unverified { try FileManager.default.removeItem(at: url) }
    }

    /// Every entry in the copy that is not a folder, with its digest; nil for a symlink or anything else that is not a regular file.
    static func copiedEntries(in directory: URL) throws -> [String: String?] {
        let base = directory.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [:] }
        var entries: [String: String?] = [:]
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true, values.isSymbolicLink != true { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            entries[relative] = values.isRegularFile == true && values.isSymbolicLink != true
                ? hex(SHA256.hash(data: try Data(contentsOf: url)))
                : String?.none
        }
        return entries
    }

    /// The copy in the cache must hold exactly the files this build shipped, byte for byte, and nothing else; anything else is removed and refused.
    static func verifyCopiedSource(_ project: URL, expected: [String: String]) throws {
        let actual = (try? copiedEntries(in: project)) ?? [:]
        guard actual == expected.mapValues(Optional.some) else {
            try? FileManager.default.removeItem(at: project)
            throw IOSDeviceError(
                .runnerBuildFailed,
                "Offsider will not build its runner: the bundled runner source does not match this Offsider build. Reinstall Offsider: brew reinstall offsider",
                hint: "brew reinstall offsider"
            )
        }
    }

    struct Signing: Equatable {
        let team: String?
        let prefix: String
    }

    func signing(for destination: RunnerDestination) throws -> Signing {
        let prefix = try Self.resolvePrefix(environment: environment)
        guard case .device = destination else { return Signing(team: nil, prefix: prefix) }
        return Signing(team: try Self.resolveTeam(environment: environment, allowanceTeam: allowanceTeam, signedInTeams: signedInTeams()), prefix: prefix)
    }

    func cacheKey(for destination: RunnerDestination, signing: Signing) throws -> String {
        let digest = try expectedSource.map(Self.sourceDigest(files:)) ?? Self.sourceDigest(of: source)
        return Self.key(sourceDigest: digest, xcodeBuild: xcode.build, team: signing.team, prefix: signing.prefix, destination: destination)
    }

    public func build(for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild {
        let signing = try signing(for: destination)
        do {
            let key = try cacheKey(for: destination, signing: signing)
            let directory = cacheRoot.appendingPathComponent(key, isDirectory: true)
            if let xctestrun = Self.xctestrun(in: directory) {
                return RunnerBuild(key: key, xctestrun: xctestrun, directory: directory)
            }
            try Self.makePrivateDirectories(directory)
            return try await Self.withBuildLock(cacheRoot.appendingPathComponent("\(key).lock")) {
                if let xctestrun = Self.xctestrun(in: directory) {
                    return RunnerBuild(key: key, xctestrun: xctestrun, directory: directory)
                }
                if case .device(let udid) = destination { try await approvePrefix(signing.prefix, udid: udid) }
                return try await runBuild(key: key, directory: directory, destination: destination, signing: signing, deviceName: deviceName)
            }
        } catch let error as IOSDeviceError {
            throw error
        } catch let approval as PrefixApproval {
            throw approval.underlying
        } catch {
            throw IOSDeviceError(
                .runnerBuildFailed,
                "Offsider could not prepare its runner build in \(cacheRoot.path): \(error.localizedDescription). Check that folder's permissions, or delete it and retry."
            )
        }
    }

    /// Asks a person before the first device build under a bundle prefix of `OFFSIDER_IOS_RUNNER_PREFIX`, which creates App IDs in their team.
    /// Only `runner build` sets it; unset, such a build is refused with the command that asks.
    @TaskLocal public static var confirmNewPrefix: (@Sendable (String) async throws -> Void)?
    static let approvedPrefixesFile = "approved-prefixes"

    /// Offsider's own prefix needs no approval; another is approved once and recorded beside the cached builds.
    func approvePrefix(_ prefix: String, udid: String) async throws {
        guard prefix != Self.defaultPrefix else { return }
        let directory = cacheRoot.path
        let recorded = (try? OffsiderPrivateDirectory.readOwnedFile(named: Self.approvedPrefixesFile, in: directory, maxBytes: 64 * 1024)) ?? nil
        var approved = recorded.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) } ?? []
        if approved.contains(prefix) { return }
        guard let confirm = Self.confirmNewPrefix else { throw PrefixApproval(underlying: RunnerPrefixNeedsPerson(prefix: prefix, udid: udid)) }
        do {
            try await confirm(prefix)
        } catch {
            throw PrefixApproval(underlying: error)
        }
        approved.append(prefix)
        try OffsiderPrivateDirectory.writeAtomically(Data(approved.joined(separator: "\n").utf8), named: Self.approvedPrefixesFile, in: directory)
    }

    /// `flock` on `<key>.lock`, polled so the task stays cancellable; the kernel drops it if this process dies.
    static func withBuildLock<T: Sendable>(_ path: URL, _ body: () async throws -> T) async throws -> T {
        let descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PrivateDirectoryError(.system(operation: "open", code: errno), path: path.path) }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(buildTimeout + 60)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: path.path) }
            guard Date() < deadline else {
                throw IOSDeviceError(.runnerBuildFailed, "Another Offsider command is still building the runner. Retry when it finishes.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }

    func arguments(project: URL, directory: URL, destination: RunnerDestination, signing: Signing) -> [String] {
        var arguments = [
            "build-for-testing",
            "-project", project.appendingPathComponent("OffsiderRunner.xcodeproj").path,
            "-scheme", "OffsiderRunner",
            "-destination", "id=\(destination.udid)",
            "-derivedDataPath", directory.appendingPathComponent("derived").path,
            "-quiet",
            "OFFSIDER_RUNNER_BUNDLE_PREFIX=\(signing.prefix)",
        ]
        if let team = signing.team {
            arguments += ["DEVELOPMENT_TEAM=\(team)", "-allowProvisioningUpdates"]
            if registerDevice { arguments.append("-allowProvisioningDeviceRegistration") }
        }
        return arguments
    }

    func runBuild(key: String, directory: URL, destination: RunnerDestination, signing: Signing, deviceName: String) async throws -> RunnerBuild {
        let project = directory.appendingPathComponent("source", isDirectory: true)
        try? FileManager.default.removeItem(at: project)
        try FileManager.default.copyItem(at: source, to: project)
        try Self.scrubCopiedSource(project)
        if let expectedSource { try Self.verifyCopiedSource(project, expected: expectedSource) }
        let log = directory.appendingPathComponent("build.log")
        let team = signing.team.map { " with team \($0)" } ?? ""
        notice("Building the Offsider runner for \(deviceName)\(team) as \(signing.prefix).runner (first time, about a minute)")
        var childEnvironment = ChildEnvironment.make(.xcodebuild, from: environment)
        childEnvironment["DEVELOPER_DIR"] = xcode.developerDirectory
        let result: ProcessCaptureResult
        do {
            result = try await xcodebuild(arguments(project: project, directory: directory, destination: destination, signing: signing), childEnvironment, Self.buildTimeout)
        } catch {
            throw Self.failure(detail: error.localizedDescription, output: "", log: log)
        }
        let output = result.stdout + result.stderr
        try? Data(output.utf8).write(to: log)
        guard result.status == 0, let xctestrun = Self.xctestrun(in: directory) else {
            if case .device(let udid) = destination, let team = signing.team, Self.needsRegistration(output) {
                throw Self.registrationFailure(udid: udid, team: team, output: output, log: log)
            }
            throw Self.failure(detail: "xcodebuild exited \(result.status)", output: output, log: log)
        }
        let record = RunnerProductsRecord(udid: destination.udid, team: signing.team, prefix: signing.prefix, products: try RunnerProducts.digests(in: directory))
        try RunnerProducts.write(record, in: directory)
        return RunnerBuild(key: key, xctestrun: xctestrun, directory: directory)
    }

    public func verifyForLaunch(_ build: RunnerBuild, for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild {
        let signing = try signing(for: destination)
        guard let problem = productProblem(build, destination: destination, signing: signing) else { return build }
        notice("Rebuilding the Offsider runner for \(deviceName): its cached build \(problem)")
        try? FileManager.default.removeItem(at: build.directory)
        let rebuilt = try await self.build(for: destination, deviceName: deviceName)
        if let again = productProblem(rebuilt, destination: destination, signing: signing) {
            try? FileManager.default.removeItem(at: rebuilt.directory)
            throw IOSDeviceError(
                .runnerBuildFailed,
                "The Offsider runner build for \(deviceName) \(again), even after a rebuild, so Offsider will not install it. Check signing for your team in Xcode, then run `offsider runner build --device \(destination.udid)`."
            )
        }
        return rebuilt
    }

    /// Why a build's products may not be installed, or nil when they match the record and, for a device, carry the team's signature.
    func productProblem(_ build: RunnerBuild, destination: RunnerDestination, signing: Signing) -> String? {
        let record: RunnerProductsRecord
        do {
            guard let read = try RunnerProducts.read(in: build.directory) else { return "has no record of its products" }
            record = read
        } catch {
            return "has a products record Offsider cannot read"
        }
        guard record.udid == destination.udid, record.team == signing.team, record.prefix == signing.prefix else {
            return "was made for another device, team or bundle prefix"
        }
        guard let current = try? RunnerProducts.digests(in: build.directory), current == record.products else {
            return "changed after it was built"
        }
        guard let team = signing.team else { return nil }
        let bundles = RunnerProducts.signedBundles(in: build.directory)
        guard bundles.hasHostApp, bundles.hasRunnerApp, bundles.hasTestBundle else { return "is missing its apps" }
        let requirement = CodeSignatureCheck.teamRequirement(team)
        if let unsigned = bundles.paths.first(where: { !signatureValid($0, requirement) }) {
            return "has \((unsigned as NSString).lastPathComponent), which is not signed by team \(team)"
        }
        return nil
    }

    static func xctestrun(in directory: URL) -> URL? {
        let products = directory.appendingPathComponent("derived/Build/Products", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? []
        return names.sorted().first { $0.hasSuffix(".xctestrun") }.map { products.appendingPathComponent($0) }
    }

    /// xcodebuild's words for a device the team has not registered, or a profile that does not cover it.
    static func needsRegistration(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["not registered", "isn't registered", "must be registered", "has no devices", "no devices", "no profiles for", "doesn't include the currently selected device", "allowprovisioningdeviceregistration"]
            .contains { text.contains($0) }
    }

    static func registrationFailure(udid: String, team: String, output: String, log: URL) -> IOSDeviceError {
        IOSDeviceError(
            .runnerBuildFailed,
            "Building the Offsider runner app failed: \(udid) is not registered with team \(team), or no provisioning profile covers it. A person registers it by running `offsider runner build --device \(udid) --register-device` in their own terminal, or in Xcode > Window > Devices and Simulators.\(tail(output))",
            hint: "offsider runner build --device \(udid) --register-device"
        )
    }

    static func failure(detail: String, output: String, log: URL) -> IOSDeviceError {
        IOSDeviceError(
            .runnerBuildFailed,
            "Building the Offsider runner app failed (\(detail)). Check signing for your team in Xcode, then retry.\(tail(output))",
            hint: "See \(log.path)"
        )
    }

    static func tail(_ output: String) -> String {
        let tail = output.split(separator: "\n", omittingEmptySubsequences: true).suffix(logTailLines).joined(separator: "\n")
        return tail.isEmpty ? "" : "\n\(tail)"
    }

    /// Each level from the cache root down, 0700.
    static func makePrivateDirectories(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for url in [directory.deletingLastPathComponent(), directory] {
            chmod(url.path, S_IRWXU)
        }
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
