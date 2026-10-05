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
}

/// `xcodebuild build-for-testing` from the bundled source into `~/Library/Caches/offsider/runner/<key>/`.
public struct XcodeRunnerBuilder: RunnerBuilding {
    public static let teamVariable = "OFFSIDER_IOS_TEAM_ID"
    static let buildTimeout: TimeInterval = 300
    static let logTailLines = 20

    let source: URL
    let cacheRoot: URL
    let xcode: XcodeLocation
    let environment: [String: String]
    let signedInTeams: @Sendable () -> [String]
    let notice: @Sendable (String) -> Void

    public init(
        source: URL,
        cacheRoot: URL,
        xcode: XcodeLocation,
        environment: [String: String],
        signedInTeams: @escaping @Sendable () -> [String],
        notice: @escaping @Sendable (String) -> Void
    ) {
        self.source = source
        self.cacheRoot = cacheRoot
        self.xcode = xcode
        self.environment = environment
        self.signedInTeams = signedInTeams
        self.notice = notice
    }

    public static func defaultCacheRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/offsider/runner", isDirectory: true)
    }

    /// `OFFSIDER_IOS_TEAM_ID`, else the one team Xcode is signed in to.
    public static func resolveTeam(environment: [String: String], signedInTeams: [String]) throws -> String {
        if let team = environment[teamVariable]?.trimmingCharacters(in: .whitespaces), !team.isEmpty {
            guard team.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                throw IOSDeviceError(.teamMissing, "\(teamVariable) must be a team ID such as ABCDE12345, not \(team).")
            }
            return team
        }
        switch Set(signedInTeams).count {
        case 1:
            return signedInTeams[0]
        case 0:
            throw IOSDeviceError(
                .teamMissing,
                "Offsider signs its runner app with your Apple development team, and Xcode is signed in to none. Add your Apple Account in Xcode > Settings > Accounts, or set \(teamVariable)."
            )
        default:
            throw IOSDeviceError(
                .teamMissing,
                "Xcode is signed in to \(Set(signedInTeams).count) development teams, so Offsider cannot pick one for its runner app. Set \(teamVariable) to the team ID to sign with."
            )
        }
    }

    /// sha256 over every source file's relative path and bytes, Xcode's build, the team and the destination.
    public static func key(sourceDigest: String, xcodeBuild: String?, team: String?, destination: RunnerDestination) -> String {
        let destinationText: String
        switch destination {
        case .device(let udid): destinationText = "iphoneos \(udid)"
        case .simulator: destinationText = "iphonesimulator"
        }
        let text = [sourceDigest, xcodeBuild ?? "unknown", team ?? "", destinationText].joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func sourceDigest(of directory: URL) throws -> String {
        var hasher = SHA256()
        for path in try sourceFiles(in: directory) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: directory.appendingPathComponent(path)))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    public func build(for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild {
        let team: String?
        if case .device = destination {
            team = try Self.resolveTeam(environment: environment, signedInTeams: signedInTeams())
        } else {
            team = nil
        }
        do {
            let key = Self.key(sourceDigest: try Self.sourceDigest(of: source), xcodeBuild: xcode.build, team: team, destination: destination)
            let directory = cacheRoot.appendingPathComponent(key, isDirectory: true)
            if let xctestrun = Self.xctestrun(in: directory) {
                return RunnerBuild(key: key, xctestrun: xctestrun, directory: directory)
            }
            try Self.makePrivateDirectories(directory)
            return try await Self.withBuildLock(cacheRoot.appendingPathComponent("\(key).lock")) {
                if let xctestrun = Self.xctestrun(in: directory) {
                    return RunnerBuild(key: key, xctestrun: xctestrun, directory: directory)
                }
                return try await runBuild(key: key, directory: directory, destination: destination, team: team, deviceName: deviceName)
            }
        } catch let error as IOSDeviceError {
            throw error
        } catch {
            throw IOSDeviceError(
                .runnerBuildFailed,
                "Offsider could not prepare its runner build in \(cacheRoot.path): \(error.localizedDescription). Check that folder's permissions, or delete it and retry."
            )
        }
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

    func runBuild(key: String, directory: URL, destination: RunnerDestination, team: String?, deviceName: String) async throws -> RunnerBuild {
        let project = directory.appendingPathComponent("source", isDirectory: true)
        try? FileManager.default.removeItem(at: project)
        try FileManager.default.copyItem(at: source, to: project)
        let log = directory.appendingPathComponent("build.log")
        notice("Building the Offsider runner for \(deviceName) (first time, about a minute)")
        var arguments = [
            "build-for-testing",
            "-project", project.appendingPathComponent("OffsiderRunner.xcodeproj").path,
            "-scheme", "OffsiderRunner",
            "-destination", "id=\(destination.udid)",
            "-derivedDataPath", directory.appendingPathComponent("derived").path,
            "-quiet",
        ]
        if let team {
            arguments += ["DEVELOPMENT_TEAM=\(team)", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"]
        }
        var childEnvironment = environment
        childEnvironment["DEVELOPER_DIR"] = xcode.developerDirectory
        let result: ProcessCaptureResult
        do {
            result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: ["xcodebuild"] + arguments, environment: childEnvironment, timeout: Self.buildTimeout)
        } catch {
            throw Self.failure(detail: error.localizedDescription, output: "", log: log)
        }
        try? Data((result.stdout + result.stderr).utf8).write(to: log)
        guard result.status == 0, let xctestrun = Self.xctestrun(in: directory) else {
            throw Self.failure(detail: "xcodebuild exited \(result.status)", output: result.stdout + result.stderr, log: log)
        }
        return RunnerBuild(key: key, xctestrun: xctestrun, directory: directory)
    }

    static func xctestrun(in directory: URL) -> URL? {
        let products = directory.appendingPathComponent("derived/Build/Products", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? []
        return names.sorted().first { $0.hasSuffix(".xctestrun") }.map { products.appendingPathComponent($0) }
    }

    static func failure(detail: String, output: String, log: URL) -> IOSDeviceError {
        let tail = output.split(separator: "\n", omittingEmptySubsequences: true).suffix(logTailLines).joined(separator: "\n")
        let shown = tail.isEmpty ? "" : "\n\(tail)"
        return IOSDeviceError(
            .runnerBuildFailed,
            "Building the Offsider runner app failed (\(detail)). Check signing for your team in Xcode, then retry.\(shown)",
            hint: "See \(log.path)"
        )
    }

    /// Each level from the cache root down, 0700.
    static func makePrivateDirectories(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for url in [directory.deletingLastPathComponent(), directory] {
            chmod(url.path, S_IRWXU)
        }
    }
}
