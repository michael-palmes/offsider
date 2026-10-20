import ArgumentParser
import Foundation
import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Show or stop the background sessions that keep devices quick to drive.",
        discussion: """
        An iPhone or iPad can have two: the XCUITest runner that reads its screen, and the session broker that holds its screen stream \
        and HID input. Each stops by itself after 300 idle seconds (OFFSIDER_IOS_RUNNER_IDLE, OFFSIDER_IOS_SESSION_IDLE). \
        An Android emulator keeps its UiAutomation helper warm, which holds the device's UiAutomation slot until it stops \
        by itself after 60 idle seconds (OFFSIDER_ANDROID_SESSION_IDLE; OFFSIDER_ANDROID_SESSION=off keeps none). \
        A simulator keeps its input session warm, which stops by itself after 60 idle seconds \
        (OFFSIDER_SIMULATOR_SESSION_IDLE; OFFSIDER_SIMULATOR_SESSION=off opens one per command).
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
        let console = Console.current
        let rows = await console.progress("Checking sessions") {
            let runners = RunnerSessions.records(device: device).map { RunnerSessionRow(record: $0, alive: XcodebuildProcesses().isRunning($0)) }
            let manager = DeviceSessions.manager()
            var brokers: [DeviceSessionStatus] = []
            for record in DeviceSessions.records(device: device) {
                brokers.append(await manager.status(of: record))
            }
            let helpers = await AndroidWarmHelpers.statuses(for: device)
            let inputs = await SimulatorInputSessions.statuses(device: device).map(\.status)
            return DeviceSessionRow.rows(runners: runners, brokers: brokers, helpers: helpers, inputs: inputs)
        }
        if json {
            console.data(DeviceSessionRow.json(rows))
            return
        }
        console.show(Page([.person(DevicePersonView.sessions(rows)), .agent(DeviceSessionRow.text(rows))]))
    }
}

struct SessionStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the runner, session broker, warm helper or input session on one device, or on every device when --device is left out."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The device whose sessions to stop.", valueName: "id"))
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
        let cleanUDID = try clean ? RunnerSessions.cleanableUDID(device ?? "", command: "session stop --clean") : nil
        let console = Console.current
        let (stopped, cleaned) = await console.progress("Stopping sessions") {
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
                RunnerSessions.removeLog(udid: record.udid)
            }
            if let device, case .iosDevice(let udid) = DeviceIDClassifier.classify(device.trimmingCharacters(in: .whitespacesAndNewlines)) {
                RunnerSessions.removeLog(udid: udid)
            }
            let serial = await AndroidWarmHelpers.serial(for: device).serial
            let helpers = await AndroidBackend.stopWarmHelpers(host: .cli(), serial: serial)
            let inputs = await SimulatorInputSessions.stop(device: device)
            let stopped = DeviceSessionRow.stopped(runners: runners.map(\.udid), brokers: brokers.map(\.udid), helpers: helpers, inputs: inputs)
            var cleaned: RunnerCleanupReport?
            if let cleanUDID {
                console.relabel("Uninstalling the runner")
                cleaned = await RunnerSessions.clean(udid: cleanUDID)
            }
            return (stopped, cleaned)
        }
        if json {
            console.data(DeviceSessionRow.stoppedJSON(stopped, clean: cleaned.map(RunnerSessions.cleanFields)) + "\n")
            return
        }
        var text = DeviceSessionRow.stoppedText(stopped, device: device)
        var person = DevicePersonView.stopped(stopped, device: device)
        var notices: [Notice] = []
        if let cleaned {
            text += RunnerSessions.cleanText(cleaned)
            let view = DevicePersonView.cleaned(cleaned)
            person += view.blocks
            notices = DevicePersonView.personOnly(view.notices, json: json, console: console)
        }
        console.show(Page([.person(person), .agent(text)], notices: notices))
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

/// `--device` as a warm helper's serial; an AVD name goes to adb only while a warm helper runs, so a status read never starts an adb server.
enum AndroidWarmHelpers {
    /// The serial, with every warm helper's status when an AVD name needed them read.
    @MainActor
    static func serial(for device: String?) async -> (serial: String?, running: [WarmHelperStatus]?) {
        guard let device = device?.trimmingCharacters(in: .whitespaces), !device.isEmpty else { return (nil, nil) }
        guard case .androidName = DeviceIDClassifier.classify(device) else { return (device, nil) }
        let running = await AndroidBackend.warmHelpers(host: .cli())
        guard !running.isEmpty, !running.contains(where: { $0.serial == device }) else { return (device, running) }
        let backend = AndroidBackend(host: .cli(), log: { _, _ in })
        let serial = try? await backend.resolveAndroidName(device)
        await backend.close()
        return (serial ?? device, running)
    }

    /// `--device`'s warm helper, or every one without it, reading each broker's status once.
    @MainActor
    static func statuses(for device: String?) async -> [WarmHelperStatus] {
        let (serial, running) = await serial(for: device)
        if let running { return running.filter { $0.serial == serial } }
        return await AndroidBackend.warmHelpers(host: .cli(), serial: serial)
    }
}

/// Each simulator's warm input session, read through its broker without counting as use.
enum SimulatorInputSessions {
    static let stopWait: Duration = .seconds(5)
    /// A broker starting when `session stop` runs answers once its session is open, which takes about as long as a command's own.
    static let startWait: Duration = .seconds(10)

    /// `waitForStarting` waits for a broker that is still opening its session, as `stop` does.
    static func statuses(device: String?, waitForStarting: Bool = false) async -> [(socket: String, status: HIDBrokerStatus)] {
        let udid = device?.trimmingCharacters(in: .whitespaces)
        var found: [(socket: String, status: HIDBrokerStatus)] = []
        for socket in HIDBroker.liveEndpoints(simulatorUDID: udid) {
            let deadline = ContinuousClock.now + startWait
            var status = await HIDBroker.offMain { HIDBroker.control(.status, at: socket)?.status }
            while status == nil, waitForStarting, HIDBroker.liveness(endpoint: socket) == .alive, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                status = await HIDBroker.offMain { HIDBroker.control(.status, at: socket)?.status }
            }
            guard let status, udid.map({ status.udid.caseInsensitiveCompare($0) == .orderedSame }) ?? true else { continue }
            found.append((socket, status))
        }
        return found
    }

    /// Asks each broker to stop and waits until it has lifted what its commands left down and exited; returns the simulators stopped.
    static func stop(device: String?) async -> [String] {
        var stopped: [String] = []
        for (socket, status) in await statuses(device: device, waitForStarting: true) {
            guard await HIDBroker.offMain({ HIDBroker.control(.stop, at: socket) }) != nil else { continue }
            let deadline = ContinuousClock.now + stopWait
            while HIDBroker.liveness(endpoint: socket) == .alive, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            stopped.append(status.udid)
        }
        return stopped
    }
}

/// One device's runner and broker, its warm Android helper, or a simulator's input session, as `session status` prints them.
struct DeviceSessionRow: Equatable {
    let device: String
    let runner: RunnerSessionRow?
    let broker: DeviceSessionStatus?
    var helper: WarmHelperStatus? = nil
    var input: HIDBrokerStatus? = nil

    static func rows(
        runners: [RunnerSessionRow], brokers: [DeviceSessionStatus], helpers: [WarmHelperStatus] = [], inputs: [HIDBrokerStatus] = []
    ) -> [DeviceSessionRow] {
        let devices = Set(runners.map(\.record.udid) + brokers.map(\.record.udid)).sorted()
        let ios = devices.map { udid in
            DeviceSessionRow(device: udid, runner: runners.first { $0.record.udid == udid }, broker: brokers.first { $0.record.udid == udid })
        }
        let simulators = inputs.sorted { $0.udid < $1.udid }.map { DeviceSessionRow(device: $0.udid, runner: nil, broker: nil, input: $0) }
        return ios + simulators + helpers.sorted { $0.serial < $1.serial }.map { DeviceSessionRow(device: $0.serial, runner: nil, broker: nil, helper: $0) }
    }

    static func text(_ rows: [DeviceSessionRow]) -> String {
        guard !rows.isEmpty else { return "No sessions.\n" }
        let formatter = ISO8601DateFormatter()
        return rows.map { row in
            var lines = ["\(row.device)"]
            if let input = row.input {
                let started = formatter.string(from: Date(timeIntervalSince1970: input.startedAt))
                lines.append("  input  \(input.state ?? "ready")  pid \(input.pid)  started \(started)  idle \(input.idleFor) s of \(input.idleSeconds) s")
                return lines.joined(separator: "\n") + "\n"
            }
            if let helper = row.helper {
                let pid = helper.helperPid.map { "  device pid \($0)" } ?? ""
                lines.append("  helper  \(helper.state)  pid \(helper.brokerPid)\(pid)  started \(formatter.string(from: helper.startedAt))  idle \(helper.idleFor) s of \(helper.idleSeconds) s")
                return lines.joined(separator: "\n") + "\n"
            }
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

    /// `{"sessions": [{"device", "runner": {...} | null, "broker": {...} | null, "helper": {...} | null}]}`; the runner's token is never printed.
    static func json(_ rows: [DeviceSessionRow]) -> String {
        let formatter = ISO8601DateFormatter()
        let sessions: [[String: Any]] = rows.map { row in
            [
                "device": row.device,
                "runner": row.runner.map { $0.fields(formatter) as Any } ?? NSNull(),
                "broker": row.broker.map { brokerFields($0, formatter) as Any } ?? NSNull(),
                "helper": row.helper.map { helperFields($0, formatter) as Any } ?? NSNull(),
                "input": row.input.map { inputFields($0, formatter) as Any } ?? NSNull(),
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

    static func helperFields(_ helper: WarmHelperStatus, _ formatter: ISO8601DateFormatter) -> [String: Any] {
        var fields: [String: Any] = [
            "state": helper.state,
            "pid": Int(helper.brokerPid),
            "startedAt": formatter.string(from: helper.startedAt),
            "idleSeconds": helper.idleSeconds,
            "idleFor": helper.idleFor,
        ]
        fields["devicePid"] = helper.helperPid.map { Int($0) as Any } ?? NSNull()
        return fields
    }

    static func inputFields(_ input: HIDBrokerStatus, _ formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "state": input.state ?? "ready",
            "pid": Int(input.pid),
            "startedAt": formatter.string(from: Date(timeIntervalSince1970: input.startedAt)),
            "idleSeconds": input.idleSeconds,
            "idleFor": input.idleFor,
            "attached": input.attached,
        ]
    }

    struct Stopped: Equatable {
        let device: String
        let runner: Bool
        let broker: Bool
        var helper = false
        var input = false

        /// `runner`, `session broker`, `warm helper` and `input session`, those that stopped.
        var parts: [String] {
            [runner ? "runner" : nil, broker ? "session broker" : nil, helper ? "warm helper" : nil, input ? "input session" : nil].compactMap { $0 }
        }
    }

    /// `Stopped the runner and session broker on <udid>.` per device, or that none was running.
    static func stoppedText(_ stopped: [Stopped], device: String?) -> String {
        guard !stopped.isEmpty else { return (device.map { "No session is running for \($0)." } ?? "No session is running.") + "\n" }
        return stopped.map { "Stopped the \($0.parts.joined(separator: " and ")) on \($0.device).\n" }.joined()
    }

    static func stopped(runners: [String], brokers: [String], helpers: [String] = [], inputs: [String] = []) -> [Stopped] {
        Set(runners + brokers + helpers + inputs).sorted().map {
            Stopped(device: $0, runner: runners.contains($0), broker: brokers.contains($0), helper: helpers.contains($0), input: inputs.contains($0))
        }
    }

    static func stoppedJSON(_ stopped: [Stopped], clean: [String: Any]? = nil) -> String {
        let entries: [[String: Any]] = stopped.map {
            ["device": $0.device, "runner": $0.runner, "broker": $0.broker, "helper": $0.helper, "input": $0.input]
        }
        var object: [String: Any] = ["stopped": entries]
        if let clean { object["clean"] = clean }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
