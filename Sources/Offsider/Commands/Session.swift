import ArgumentParser
import Foundation
import OffsiderCore
import OffsiderIOSDevice

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Show or stop the background sessions that serve physical iPhones and iPads.",
        discussion: """
        Each device can have two: the XCUITest runner that reads its screen, and the session broker that holds its screen stream \
        and HID input so commands answer in milliseconds. Each stops by itself after 300 idle seconds \
        (OFFSIDER_IOS_RUNNER_IDLE, OFFSIDER_IOS_SESSION_IDLE).
        """,
        subcommands: [SessionStatus.self, SessionStop.self]
    )
}

struct SessionStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "List each device's runner and session broker, without starting either."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("Only this device's sessions.", valueName: "id"))
    var device: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of text.")
    var json = false

    @MainActor
    func run() async throws {
        let runners = RunnerSessions.records(device: device).map { RunnerSessionRow(record: $0, alive: XcodebuildProcesses().isRunning($0)) }
        let manager = DeviceSessions.manager()
        var brokers: [DeviceSessionStatus] = []
        for record in DeviceSessions.records(device: device) {
            brokers.append(await manager.status(of: record))
        }
        let rows = DeviceSessionRow.rows(runners: runners, brokers: brokers)
        print(json ? DeviceSessionRow.json(rows) : DeviceSessionRow.text(rows), terminator: "")
    }
}

struct SessionStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the runner and session broker on one device, or on every device when --device is left out."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The device whose sessions to stop.", valueName: "id"))
    var device: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of text.")
    var json = false

    @MainActor
    func run() async throws {
        let brokers = DeviceSessions.records(device: device)
        let manager = DeviceSessions.manager()
        for record in brokers {
            await manager.stop(record)
        }
        let runners = RunnerSessions.records(device: device)
        let runnerManager = RunnerSessionManager(
            store: RunnerSessions.store,
            builder: UnusedRunnerBuilder(),
            environment: ProcessInfo.processInfo.environment,
            developerDirectory: nil,
            log: { _, _ in }
        )
        for record in runners {
            await runnerManager.stop(record)
        }
        let stopped = DeviceSessionRow.stopped(runners: runners.map(\.udid), brokers: brokers.map(\.udid))
        if json {
            print(DeviceSessionRow.stoppedJSON(stopped))
        } else if stopped.isEmpty {
            print(device.map { "No session is running for \($0)." } ?? "No session is running.")
        } else {
            for entry in stopped {
                let parts = [entry.runner ? "runner" : nil, entry.broker ? "session broker" : nil].compactMap { $0 }
                print("Stopped the \(parts.joined(separator: " and ")) on \(entry.device).")
            }
        }
    }
}

enum DeviceSessions {
    static var store: DeviceSessionStore { DeviceSessionStore(root: OffsiderPrivateDirectory.root) }

    @MainActor
    static func manager() -> DeviceSessionManager {
        DeviceSessionManager(
            store: store,
            processes: OffsiderSelfProcesses(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])),
            environment: ProcessInfo.processInfo.environment,
            log: { _, _ in }
        )
    }

    static func records(device: String?) -> [DeviceSessionRecord] {
        let all = store.all()
        guard let device else { return all }
        return all.filter { $0.udid.caseInsensitiveCompare(device.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
}

/// One device's runner and broker, as `session status` prints them.
struct DeviceSessionRow: Equatable {
    let device: String
    let runner: RunnerSessionRow?
    let broker: DeviceSessionStatus?

    static func rows(runners: [RunnerSessionRow], brokers: [DeviceSessionStatus]) -> [DeviceSessionRow] {
        let devices = Set(runners.map(\.record.udid) + brokers.map(\.record.udid)).sorted()
        return devices.map { udid in
            DeviceSessionRow(device: udid, runner: runners.first { $0.record.udid == udid }, broker: brokers.first { $0.record.udid == udid })
        }
    }

    static func text(_ rows: [DeviceSessionRow]) -> String {
        guard !rows.isEmpty else { return "No sessions.\n" }
        let formatter = ISO8601DateFormatter()
        return rows.map { row in
            var lines = ["\(row.device)"]
            if let runner = row.runner {
                let state = !runner.alive ? "stopped" : runner.record.state == .starting ? "starting" : "running"
                lines.append("  runner  \(state)  pid \(runner.record.pid)  started \(formatter.string(from: runner.record.startedAt))  last used \(formatter.string(from: runner.record.lastUsed))")
            } else {
                lines.append("  runner  not running")
            }
            if let broker = row.broker {
                lines.append("  broker  \(brokerState(broker))  pid \(broker.record.pid)  started \(formatter.string(from: broker.record.startedAt))  stream \(streamText(broker.reply?.stream))")
            } else {
                lines.append("  broker  not running")
            }
            return lines.joined(separator: "\n") + "\n"
        }.joined()
    }

    static func brokerState(_ status: DeviceSessionStatus) -> String {
        if !status.alive { return "stopped" }
        return status.reply == nil ? "not answering" : "running"
    }

    static func streamText(_ stream: DeviceSessionStreamStatus?) -> String {
        guard let stream else { return "unknown" }
        switch stream.state {
        case .live: return "live \(stream.width ?? 0) x \(stream.height ?? 0), \(stream.framesReceived ?? 0) frames"
        case .failed: return "failed: \(stream.detail ?? "unknown")"
        case .opening, .closed: return stream.state.rawValue
        }
    }

    /// `{"sessions": [{"device", "runner": {...} | null, "broker": {...} | null}]}`; the runner's token is never printed.
    static func json(_ rows: [DeviceSessionRow]) -> String {
        let formatter = ISO8601DateFormatter()
        let sessions: [[String: Any]] = rows.map { row in
            [
                "device": row.device,
                "runner": row.runner.map { $0.fields(formatter) as Any } ?? NSNull(),
                "broker": row.broker.map { brokerFields($0, formatter) as Any } ?? NSNull(),
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["sessions": sessions], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func brokerFields(_ status: DeviceSessionStatus, _ formatter: ISO8601DateFormatter) -> [String: Any] {
        var fields: [String: Any] = [
            "running": status.alive,
            "answering": status.reply != nil,
            "pid": Int(status.record.pid),
            "startedAt": formatter.string(from: status.record.startedAt),
            "version": status.record.version,
        ]
        if let stream = status.reply?.stream {
            var streamFields: [String: Any] = ["state": stream.state.rawValue]
            streamFields["width"] = stream.width
            streamFields["height"] = stream.height
            streamFields["framesReceived"] = stream.framesReceived
            streamFields["detail"] = stream.detail
            fields["stream"] = streamFields
        } else {
            fields["stream"] = NSNull()
        }
        if let touch = status.reply?.touch { fields["touch"] = touch }
        return fields
    }

    struct Stopped: Equatable {
        let device: String
        let runner: Bool
        let broker: Bool
    }

    static func stopped(runners: [String], brokers: [String]) -> [Stopped] {
        Set(runners + brokers).sorted().map { Stopped(device: $0, runner: runners.contains($0), broker: brokers.contains($0)) }
    }

    static func stoppedJSON(_ stopped: [Stopped]) -> String {
        let entries: [[String: Any]] = stopped.map { ["device": $0.device, "runner": $0.runner, "broker": $0.broker] }
        let data = (try? JSONSerialization.data(withJSONObject: ["stopped": entries], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
