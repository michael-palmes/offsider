import ArgumentParser
import Foundation
import OffsiderCore
import OffsiderIOSDevice

struct RunnerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runner",
        abstract: "Show or stop the XCUITest runner that reads physical iPhones and iPads.",
        discussion: """
        Offsider builds a small runner app the first time it reads a phone's screen, then keeps it running in the \
        background so later commands answer quickly; it stops by itself after 300 idle seconds (OFFSIDER_IOS_RUNNER_IDLE).
        """,
        subcommands: [RunnerStatus.self, RunnerBuildCommand.self, RunnerStop.self]
    )
}

struct RunnerBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build the runner app for an allowed, wired iPhone or iPad, or check its cached build.",
        discussion: """
        The runner is signed with the team `device-access allow` recorded for the device, else OFFSIDER_IOS_TEAM_ID; a variable naming \
        another team than the allowance's is refused. Offsider never registers a device with a team on its own: --register-device lets \
        Xcode add this device to the team, and only a person in their own terminal, with Touch ID or their password, can pass it. \
        The first build under a new OFFSIDER_IOS_RUNNER_PREFIX asks the same way. Xcode > Window > Devices and Simulators registers a device too.
        """
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The iPhone or iPad's UDID. OFFSIDER_DEVICE is never read.", valueName: "id"))
    var device: String

    @Flag(name: .customLong("register-device"), help: "Let Xcode register the device with the team while building; needs a person at a terminal.")
    var registerDevice = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of text.")
    var json = false

    /// A new OFFSIDER_IOS_RUNNER_PREFIX creates App IDs in the person's team, so its first build needs a terminal and Touch ID or the password.
    static func confirmPrefix(udid: String) -> @Sendable (String) async throws -> Void {
        { prefix in
            try PersonPresence.requireTerminal(instead: "Ask the user to run `offsider runner build --device \(udid)` in their own terminal.")
            try await PersonPresence.confirm(reason: "build Offsider's runner under the new bundle prefix \(prefix) in your Apple developer team")
        }
    }

    @MainActor
    func run() async throws {
        let udid = try RunnerSessions.physicalUDID(device, command: "runner build")
        if registerDevice {
            let instead = "Ask the user to run `offsider runner build --device \(udid) --register-device` in their own terminal."
            try PersonPresence.requireTerminal(instead: instead)
            guard isatty(STDOUT_FILENO) != 0 else {
                throw CLIError.personRequired("This step needs a person at a terminal, and standard output is not one. Nothing was changed. \(instead)")
            }
            try await PersonPresence.confirm(reason: "register the iPhone or iPad \(udid) with your Apple developer team")
        }
        let route = try await DeviceRouter.route(udid, logger: OffsiderLogger())
        guard let backend = route.backend as? IOSDeviceBackend else {
            throw CLIError(errorDescription: "runner build is for a physical iPhone or iPad, and \(udid) is not one.", reason: .usage)
        }
        let build = try await XcodeRunnerBuilder.$confirmNewPrefix.withValue(Self.confirmPrefix(udid: udid)) {
            try await backend.buildRunner(for: route.device, registerDevice: registerDevice)
        }
        if json {
            let data = try JSONSerialization.data(withJSONObject: ["device": udid, "key": build.key, "directory": build.directory.path], options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("The Offsider runner for \(udid) is built and its signature checked (\(build.directory.path)).")
        }
    }
}

struct RunnerStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "List the runner sessions this Mac holds, one per phone."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("Only this phone's session.", valueName: "id"))
    var device: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of text.")
    var json = false

    func run() async throws {
        let rows = RunnerSessions.records(device: device).map { record in
            RunnerSessionRow(record: record, alive: XcodebuildProcesses().isRunning(record))
        }
        print(json ? RunnerSessionRow.json(rows) : RunnerSessionRow.text(rows), terminator: "")
    }
}

struct RunnerStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the runner on one phone, or on every phone when --device is left out."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The phone whose runner to stop.", valueName: "id"))
    var device: String?

    @Flag(name: .customLong("clean"), help: "Also uninstall the runner from the device and delete its cached builds and logs; needs --device.")
    var clean = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of text.")
    var json = false

    func validate() throws {
        if clean, device == nil { throw ValidationError(RunnerSessions.cleanNeedsDevice) }
    }

    @MainActor
    func run() async throws {
        let cleanUDID = try clean ? RunnerSessions.cleanableUDID(device ?? "", command: "runner stop --clean") : nil
        let records = RunnerSessions.records(device: device)
        let manager = RunnerSessionManager(
            store: RunnerSessions.store,
            builder: UnusedRunnerBuilder(),
            environment: ProcessInfo.processInfo.environment,
            developerDirectory: nil,
            log: { _, _ in }
        )
        for record in records {
            await manager.stop(record)
            RunnerSessions.removeLog(udid: record.udid)
        }
        if let device, case .iosDevice(let udid) = DeviceIDClassifier.classify(device.trimmingCharacters(in: .whitespacesAndNewlines)) {
            RunnerSessions.removeLog(udid: udid)
        }
        let stopped = records.map(\.udid)
        var cleaned: RunnerCleanupReport?
        if let cleanUDID { cleaned = await RunnerSessions.clean(udid: cleanUDID) }
        if json {
            var object: [String: Any] = ["stopped": stopped]
            if let cleaned { object["clean"] = RunnerSessions.cleanFields(cleaned) }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            if stopped.isEmpty {
                print(device.map { "No runner is running for \($0)." } ?? "No runner is running.")
            } else {
                for udid in stopped { print("Stopped the runner on \(udid).") }
            }
            if let cleaned { print(RunnerSessions.cleanText(cleaned), terminator: "") }
        }
    }
}

enum RunnerSessions {
    static var store: RunnerSessionStore { RunnerSessionStore(root: OffsiderPrivateDirectory.root) }

    static let cleanNeedsDevice = "--clean needs --device <udid>: it uninstalls the runner from that one iPhone or iPad."

    /// The UDID of a physical iPhone or iPad named on the command line, or a usage error.
    static func physicalUDID(_ raw: String, command: String) throws -> String {
        guard case .iosDevice(let udid) = DeviceIDClassifier.classify(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CLIError(
                errorDescription: "`offsider \(command)` is for a physical iPhone or iPad, named by its UDID with --device; \(raw.isEmpty ? "none was given" : "\(raw) is not one").",
                reason: .usage, hint: "offsider devices --physical"
            )
        }
        return udid
    }

    /// `--clean` only removes what Offsider put there, so a device allowed now or once (its runner built or running here) may be cleaned after its allowance lapsed or was removed.
    static func cleanableUDID(
        _ raw: String, command: String, gate: DevicePolicyGate = DevicePolicyGate.current,
        hasRunnerRecord: (String) -> Bool = { RunnerSessions.hasRecord(udid: $0) }
    ) throws -> String {
        let udid = try physicalUDID(raw, command: command)
        if case .refused(let refusal) = gate.decision(platform: .ios, key: udid.uppercased()) {
            guard !refusal.isManaged, hasRunnerRecord(udid) else {
                throw CLIError.deviceNotAllowed(name: nil, key: udid.uppercased(), refusal: refusal)
            }
        }
        return udid
    }

    /// A runner build or session this Mac holds for the device, which only an allowance could have made.
    static func hasRecord(udid: String) -> Bool {
        !records(device: udid).isEmpty
            || RunnerCleanup.hasBuild(for: udid, cacheRoot: XcodeRunnerBuilder.defaultCacheRoot(home: FileManager.default.homeDirectoryForCurrentUser))
    }

    /// `runner.log` can hold what the runner was asked to do, so a stop deletes it.
    static func removeLog(udid: String) {
        store.removeLog(udid: udid)
    }

    /// Uninstalls the runner apps, then deletes this device's cached builds, `runner.log` and the broker's log. Its sessions must be stopped first.
    @MainActor
    static func clean(udid: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> RunnerCleanupReport {
        let prefix = (try? XcodeRunnerBuilder.resolvePrefix(environment: environment)) ?? XcodeRunnerBuilder.defaultPrefix
        let logs = [try? store.logPath(udid: udid), try? DeviceSessions.store.logPath(udid: udid)].compactMap { $0 }
        return await RunnerCleanup.clean(
            udid: udid, cacheRoot: XcodeRunnerBuilder.defaultCacheRoot(home: FileManager.default.homeDirectoryForCurrentUser),
            environmentPrefix: prefix, devicectl: XcrunDevicectl(environment: environment), logPaths: logs
        )
    }

    static func cleanText(_ report: RunnerCleanupReport) -> String {
        var lines: [String] = []
        if !report.uninstalled.isEmpty {
            lines.append("Uninstalled \(report.uninstalled.joined(separator: " and ")) from \(report.udid).")
        }
        for (bundleID, detail) in report.notUninstalled.sorted(by: { $0.key < $1.key }) {
            lines.append("Did not uninstall \(bundleID) from \(report.udid): \(detail)")
        }
        let builds = report.removedBuilds == 1 ? "1 cached runner build" : "\(report.removedBuilds) cached runner builds"
        let logs = report.removedLogs.isEmpty ? "" : " and \(report.removedLogs.count == 1 ? "1 log" : "\(report.removedLogs.count) logs")"
        lines.append("Deleted \(builds)\(logs) for \(report.udid).")
        lines.append(report.remains)
        return lines.joined(separator: "\n") + "\n"
    }

    static func cleanFields(_ report: RunnerCleanupReport) -> [String: Any] {
        [
            "device": report.udid,
            "uninstalled": report.uninstalled,
            "notUninstalled": report.notUninstalled,
            "removedBuilds": report.removedBuilds,
            "removedLogs": report.removedLogs,
            "remains": report.remains,
        ]
    }

    static func records(device: String?) -> [RunnerSessionRecord] {
        let all = store.all()
        guard let device else { return all }
        return all.filter { $0.udid.caseInsensitiveCompare(device.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
}

/// `runner stop` never builds; a stop that reaches the builder is a bug.
struct UnusedRunnerBuilder: RunnerBuilding {
    func build(for destination: RunnerDestination, deviceName: String) async throws -> RunnerBuild {
        throw CLIError(errorDescription: "Unexpected runner build while stopping.", reason: .internalError)
    }
}

struct RunnerSessionRow: Equatable {
    let record: RunnerSessionRecord
    let alive: Bool

    static func text(_ rows: [RunnerSessionRow]) -> String {
        guard !rows.isEmpty else { return "No runner sessions.\n" }
        let formatter = ISO8601DateFormatter()
        return rows.map { row in
            let state = !row.alive ? "stopped" : row.record.state == .starting ? "starting" : "running"
            return "\(row.record.udid)  \(state)  pid \(row.record.pid)  port \(row.record.port)  started \(formatter.string(from: row.record.startedAt))  last used \(formatter.string(from: row.record.lastUsed))\n"
        }.joined()
    }

    /// The token stays in the session file; it is never printed.
    static func json(_ rows: [RunnerSessionRow]) -> String {
        let formatter = ISO8601DateFormatter()
        let sessions: [[String: Any]] = rows.map { row in
            var fields = row.fields(formatter)
            fields["device"] = row.record.udid
            return fields
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["sessions": sessions], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    func fields(_ formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "running": alive,
            "pid": Int(record.pid),
            "port": Int(record.port),
            "startedAt": formatter.string(from: record.startedAt),
            "lastUsed": formatter.string(from: record.lastUsed),
            "version": record.version,
        ]
    }
}
