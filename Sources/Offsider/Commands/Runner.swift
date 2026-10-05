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
        subcommands: [RunnerStatus.self, RunnerStop.self]
    )
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

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of text.")
    var json = false

    @MainActor
    func run() async throws {
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
        }
        let stopped = records.map(\.udid)
        if json {
            let data = try JSONSerialization.data(withJSONObject: ["stopped": stopped], options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else if stopped.isEmpty {
            print(device.map { "No runner is running for \($0)." } ?? "No runner is running.")
        } else {
            for udid in stopped { print("Stopped the runner on \(udid).") }
        }
    }
}

enum RunnerSessions {
    static var store: RunnerSessionStore { RunnerSessionStore(root: OffsiderPrivateDirectory.root) }

    static func records(device: String?) -> [RunnerSessionRecord] {
        let all = store.all()
        guard let device else { return all }
        return all.filter { $0.udid.caseInsensitiveCompare(device.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
}

/// `runner stop` never builds; a stop that reaches the builder is a bug.
private struct UnusedRunnerBuilder: RunnerBuilding {
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
            [
                "device": row.record.udid,
                "running": row.alive,
                "pid": Int(row.record.pid),
                "port": Int(row.record.port),
                "startedAt": formatter.string(from: row.record.startedAt),
                "lastUsed": formatter.string(from: row.record.lastUsed),
                "version": row.record.version,
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["sessions": sessions], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
