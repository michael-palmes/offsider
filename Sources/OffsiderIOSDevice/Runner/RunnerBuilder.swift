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
    public static let defaultPrefix = DeviceAllowance.defaultRunnerPrefix
    static let buildTimeout: TimeInterval = 300
    static let logTailLines = 20
    static let logName = "build.log"
    static let maxLogBytes = 4 << 20

    let source: URL
    let cacheRoot: URL
    let xcode: XcodeLocation
    let environment: [String: String]
    let signedInTeams: @Sendable () -> [String]
    let notice: @Sendable (String) -> Void
    /// The device's allowance: the team and runner prefix a person chose for it in `devices add`.
    let allowance: DeviceAllowance?
    /// The runner source's digests compiled into this binary, keyed by path below `runner/`; nil hashes the source folder instead.
    let expectedSource: [String: String]?
    /// Lets xcodebuild register the device with the team; only `runner build --register-device` sets it.
    let registerDevice: Bool
    let xcodebuild: XcodebuildRunning
    /// Whether the bundle at a path is validly signed and satisfies a requirement, sealed resources included.
    let signatureValid: @Sendable (_ path: String, _ requirement: String) -> Bool
    let now: @Sendable () -> Date

    public init(
        source: URL,
        cacheRoot: URL,
        xcode: XcodeLocation,
        environment: [String: String],
        signedInTeams: @escaping @Sendable () -> [String],
        notice: @escaping @Sendable (String) -> Void,
        allowance: DeviceAllowance? = nil,
        expectedSource: [String: String]? = nil,
        registerDevice: Bool = false,
        xcodebuild: @escaping XcodebuildRunning = XcodeRunnerBuilder.runXcodebuild,
        signatureValid: @escaping @Sendable (String, String) -> Bool = { CodeSignatureCheck.satisfies(path: $0, requirement: $1, resources: true) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.cacheRoot = cacheRoot
        self.xcode = xcode
        self.environment = environment
        self.signedInTeams = signedInTeams
        self.notice = notice
        self.allowance = allowance
        self.expectedSource = expectedSource
        self.registerDevice = registerDevice
        self.xcodebuild = xcodebuild
        self.signatureValid = signatureValid
        self.now = now
    }

    var allowanceTeam: String? { allowance?.team }
    var allowancePrefix: String? { allowance?.runnerPrefix }

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

    /// The allowance's prefix, else `OFFSIDER_IOS_RUNNER_PREFIX`, else `com.mpalmes.offsider` (apps `<prefix>.runner` and `.runner.uitests`); a variable naming another prefix than the person chose is refused.
    public static func resolvePrefix(environment: [String: String], allowancePrefix: String? = nil) throws -> String {
        let chosen = allowancePrefix.flatMap { DeviceAllowance.isRunnerPrefix($0) ? $0 : nil }
        guard let value = environment[prefixVariable]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return chosen ?? defaultPrefix }
        guard DeviceAllowance.isRunnerPrefix(value) else {
            throw IOSDeviceError(
                .invalidSetting,
                "\(prefixVariable) must be a reverse-DNS bundle id prefix of at most \(DeviceAllowance.maximumRunnerPrefixLength) characters, such as com.example.offsider, not \(value)."
            )
        }
        if let chosen, chosen != value {
            throw IOSDeviceError(
                .invalidSetting,
                "\(prefixVariable) is \(value), but this device's allowance names runner prefix \(chosen), and the prefix a person chose wins. Unset \(prefixVariable), or give the device that prefix again in `offsider devices add`.",
                hint: "offsider devices add"
            )
        }
        return value
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
        let prefix = try Self.resolvePrefix(environment: environment, allowancePrefix: allowancePrefix)
        guard case .device = destination else { return Signing(team: nil, prefix: prefix) }
        let team = try Self.resolveTeam(environment: environment, allowanceTeam: allowanceTeam, signedInTeams: signedInTeams())
        if let why = ManagedGate.teamRefusal(team) {
            throw IOSDeviceError(.managedPolicy, "\(ManagedRefusalText.sentence(why)) The runner was not built. Ask the administrator of this Mac.")
        }
        return Signing(team: team, prefix: prefix)
    }

    func cacheKey(for destination: RunnerDestination, signing: Signing) throws -> String {
        let digest = try expectedSource.map(Self.sourceDigest(files:)) ?? Self.sourceDigest(of: source)
        return Self.key(sourceDigest: digest, xcodeBuild: xcode.build, team: signing.team, prefix: signing.prefix, destination: destination)
    }

    public func build(for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild {
        try await build(for: destination, deviceName: deviceName, renewing: nil)
    }

    /// `renewing` is the expiry of the profile this build replaces, so a build that fails says the profile could not be renewed.
    func build(for destination: RunnerDestination, deviceName: String, renewing: Date?) async throws -> RunnerBuild {
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
                return try await runBuild(key: key, directory: directory, destination: destination, signing: signing, renewing: renewing)
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

    /// The prefixes a person approved at `runner build`, recorded beside the cached builds.
    func approvedPrefixes() -> [String] {
        let recorded = (try? OffsiderPrivateDirectory.readOwnedFile(named: Self.approvedPrefixesFile, in: cacheRoot.path, maxBytes: 64 * 1024)) ?? nil
        return recorded.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) } ?? []
    }

    /// Offsider's own prefix and the one a person sealed into the device's allowance under Touch ID need no approval; the environment's alone never counts.
    func needsApproval(_ prefix: String) -> Bool {
        prefix != Self.defaultPrefix && prefix != allowancePrefix && !approvedPrefixes().contains(prefix)
    }

    /// Another prefix is approved once at a terminal and recorded beside the cached builds.
    func approvePrefix(_ prefix: String, udid: String) async throws {
        guard needsApproval(prefix) else { return }
        let directory = cacheRoot.path
        var approved = approvedPrefixes()
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
            arguments.append("DEVELOPMENT_TEAM=\(team)")
            // Without the flag xcodebuild signs only with profiles already on this Mac: it creates no App ID, profile or device record.
            if ManagedGate.refusal(.allowRunnerRegistration) == nil {
                arguments.append("-allowProvisioningUpdates")
                if registerDevice { arguments.append("-allowProvisioningDeviceRegistration") }
            }
        }
        return arguments
    }

    func runBuild(key: String, directory: URL, destination: RunnerDestination, signing: Signing, renewing: Date? = nil) async throws -> RunnerBuild {
        let project = directory.appendingPathComponent("source", isDirectory: true)
        try? FileManager.default.removeItem(at: project)
        try FileManager.default.copyItem(at: source, to: project)
        try Self.scrubCopiedSource(project)
        if let expectedSource { try Self.verifyCopiedSource(project, expected: expectedSource) }
        let log = directory.appendingPathComponent(Self.logName)
        let team = signing.team.map { " with team \($0)" } ?? ""
        notice("Building the Offsider runner\(team) as \(signing.prefix).runner (first time, about a minute)")
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
            if case .device(let udid) = destination, let team = signing.team {
                // Another team's App ID also leaves no profile, which reads as a registration failure, so it is checked first.
                if Self.appIDTaken(output) {
                    throw appIDTakenFailure(udid: udid, team: team, prefix: signing.prefix, appID: Self.takenAppID(in: output, prefix: signing.prefix))
                }
                // With no account, xcodebuild also says it found no profiles, which reads as a registration failure.
                if let renewing, Self.accountMissing(output) { throw profileExpired(udid: udid, team: team, expiry: renewing, output: output) }
                if Self.needsRegistration(output) {
                    throw Self.registrationFailure(udid: udid, team: team, output: output, log: log, managed: ManagedGate.refusal(.allowRunnerRegistration))
                }
                if let renewing { throw profileExpired(udid: udid, team: team, expiry: renewing, output: output) }
            }
            throw Self.failure(detail: "xcodebuild exited \(result.status)", output: output, log: log)
        }
        let record = RunnerProductsRecord(udid: destination.udid, team: signing.team, prefix: signing.prefix, products: try RunnerProducts.digests(in: directory))
        try RunnerProducts.write(record, in: directory)
        return RunnerBuild(key: key, xctestrun: xctestrun, directory: directory)
    }

    public func verifyForLaunch(_ build: RunnerBuild, for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild {
        let signing = try signing(for: destination)
        let problem = productProblem(build, destination: destination, signing: signing)
        let expiry = problem == nil ? expiringProfile(build, signing: signing) : nil
        guard let reason = problem ?? expiry.map(profileProblem) else { return build }
        notice("Rebuilding the Offsider runner for \(deviceName): its cached build \(reason)")
        try? FileManager.default.removeItem(at: build.directory)
        let rebuilt = try await self.build(for: destination, deviceName: deviceName, renewing: expiry)
        // Xcode can hand back a profile that is close to its end but still valid; that build still launches.
        if expiry != nil, let team = signing.team, let still = expiringProfile(rebuilt, signing: signing), still <= now() {
            try? FileManager.default.removeItem(at: rebuilt.directory)
            throw profileExpired(udid: destination.udid, team: team, expiry: still, output: "")
        }
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

    /// The earliest expiry among the installed apps' embedded profiles, when it falls within `ProvisioningProfile.renewalMargin`; nil for a simulator build or a profile this cannot read.
    func expiringProfile(_ build: RunnerBuild, signing: Signing) -> Date? {
        guard signing.team != nil else { return nil }
        let apps = RunnerProducts.signedBundles(in: build.directory).paths.filter { $0.hasSuffix(".app") }
        guard let earliest = apps.compactMap(ProvisioningProfile.expiry(inBundle:)).min() else { return nil }
        return earliest < now().addingTimeInterval(ProvisioningProfile.renewalMargin) ? earliest : nil
    }

    func profileProblem(_ expiry: Date) -> String {
        "has a provisioning profile that \(expiry <= now() ? "expired" : "expires") on \(IOSDeviceDoctorRules.profileDay(expiry))"
    }

    /// xcodebuild's words when Xcode has no Apple Account to sign with.
    static func accountMissing(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["no accounts", "no account for team", "not signed in"].contains { text.contains($0) }
    }

    /// Xcode signs with an account signed in to it; an agent's shell may have none, so the renewal is a person's step.
    func profileExpired(udid: String, team: String, expiry: Date, output: String) -> IOSDeviceError {
        let command = "offsider runner build --device \(udid)"
        let when = "\(expiry <= now() ? "expired" : "expires") on \(IOSDeviceDoctorRules.profileDay(expiry))"
        let step = ErrorAudience.current == .person
            ? "Sign in to Xcode (Settings > Accounts) with team \(team)'s Apple Account, then run `\(command)`."
            : "A person signs in to Xcode (Settings > Accounts) with team \(team)'s Apple Account, then runs `\(command)` in their own terminal."
        return IOSDeviceError(
            .profileExpired,
            "The Offsider runner's provisioning profile \(when), and Xcode could not renew it here, as when no Apple Account for team \(team) is signed in. \(step)\(Self.tail(output))",
            hint: command
        )
    }

    static func xctestrun(in directory: URL) -> URL? {
        let products = directory.appendingPathComponent("derived/Build/Products", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? []
        return names.sorted().first { $0.hasSuffix(".xctestrun") }.map { products.appendingPathComponent($0) }
    }

    /// Apple's words when one of the runner's App IDs belongs to another team: it "cannot be registered to your development team" or "is not available".
    static func appIDTaken(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("cannot be registered to your development team") || (text.contains("app id with identifier") && text.contains("is not available"))
    }

    /// The first runner App ID xcodebuild quotes, else the host app's; never text from the log itself.
    static func takenAppID(in output: String, prefix: String) -> String {
        let ids = ["\(prefix).runner", "\(prefix).runner.uitests", "\(prefix).runner.uitests.xctrunner"]
        let found = ids.compactMap { id in
            ["\"\(id)\"", "'\(id)'", "\u{201C}\(id)\u{201D}"].compactMap { output.range(of: $0)?.lowerBound }.min().map { (id, $0) }
        }
        return found.min { $0.1 < $1.1 }?.0 ?? "\(prefix).runner"
    }

    /// The one command that gives the device a prefix of its own: on the allow-list, `devices add`, which also saves it, keeping the device's use and team.
    func appIDFix(udid: String, team: String, prefix: String) -> String {
        let fresh = DeviceAllowance.suggestedRunnerPrefix(team: team, avoiding: prefix)
        if let allowance { return DeviceAddPlan.runnerPrefixCommand(allowance, team: team, prefix: fresh) }
        return "\(Self.prefixVariable)=\(fresh) offsider runner build --device \(udid)"
    }

    func appIDTakenFailure(udid: String, team: String, prefix: String, appID: String) -> IOSDeviceError {
        let fix = appIDFix(udid: udid, team: team, prefix: prefix)
        let saves = allowance == nil ? "" : ", which saves the prefix for this device and builds the runner"
        return IOSDeviceError(
            .runnerBuildFailed,
            "Building the Offsider runner app failed: another Apple team already owns its App ID \(appID), so team \(team) needs a runner prefix of its own. A person runs `\(fix)` once in their own terminal and confirms with Touch ID\(saves).",
            hint: fix
        )
    }

    /// What the cache holds for the device's team and prefix, read without building, asking or starting anything: doctor's view. Nil when no team is settled or the source is unreadable.
    public func cacheStatus(udid: String) -> IOSDeviceDoctorFacts.RunnerBuildFact? {
        let destination = RunnerDestination.device(udid: udid)
        let signing: Signing
        do {
            signing = try self.signing(for: destination)
        } catch let error as IOSDeviceError where error.kind == .invalidSetting || error.kind == .managedPolicy {
            return .unsettled(message: error.message, hint: error.hint)
        } catch {
            return nil
        }
        guard let team = signing.team, let key = try? cacheKey(for: destination, signing: signing) else { return nil }
        let directory = cacheRoot.appendingPathComponent(key, isDirectory: true)
        if Self.xctestrun(in: directory) != nil {
            let build = RunnerBuild(key: key, xctestrun: directory, directory: directory)
            if let expiry = expiringProfile(build, signing: signing) {
                return .profileExpiring(team: team, prefix: signing.prefix, expires: expiry, expired: expiry <= now())
            }
            return .built(team: team, prefix: signing.prefix)
        }
        let log = directory.appendingPathComponent(Self.logName)
        let output = UntrustedRead.contents(atPath: log.path, maxBytes: Self.maxLogBytes, truncate: true).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if Self.appIDTaken(output) {
            return .appIDTaken(appID: Self.takenAppID(in: output, prefix: signing.prefix), team: team, fix: appIDFix(udid: udid, team: team, prefix: signing.prefix))
        }
        if Self.needsRegistration(output) { return .notRegistered(team: team) }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .notBuilt(team: team, prefix: signing.prefix, needsPerson: needsApproval(signing.prefix)) }
        return .failed(team: team, prefix: signing.prefix, log: log.path)
    }

    /// xcodebuild's words for a device the team has not registered, or a profile that does not cover it.
    static func needsRegistration(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["not registered", "isn't registered", "must be registered", "has no devices", "no devices", "no profiles for", "doesn't include the currently selected device", "allowprovisioningdeviceregistration"]
            .contains { text.contains($0) }
    }

    static func registrationFailure(udid: String, team: String, output: String, log: URL, managed: String? = nil) -> IOSDeviceError {
        if let managed {
            return IOSDeviceError(
                .managedPolicy,
                "Building the Offsider runner app failed: \(udid) is not registered with team \(team), or no provisioning profile covers it, and \(managed). Register it in Xcode > Window > Devices and Simulators, or ask the administrator of this Mac.\(tail(output))"
            )
        }
        return IOSDeviceError(
            .runnerBuildFailed,
            "Building the Offsider runner app failed: \(udid) is not registered with team \(team), or no provisioning profile covers it. A person registers it by running `offsider runner build --register-device --device \(udid)` in their own terminal, or in Xcode > Window > Devices and Simulators.\(tail(output))",
            hint: "offsider runner build --register-device --device \(udid)"
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
