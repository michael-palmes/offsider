import Foundation
import OffsiderCore

extension AndroidBackend: LogReading {
    /// `logcat -d` for history, or `logcat` over a shell stream until the window ends or the task is cancelled.
    public func readLogs(_ query: LogQuery, on id: DeviceID, onEntry: @escaping @MainActor (LogEntry) -> Void) async throws {
        guard query.predicate == nil else {
            throw AndroidError(.notSupported, "--predicate is iOS only; on Android use --app, --rn or --grep.")
        }
        try await prepare()
        let serial = id.rawValue
        let client = try requireClient()
        var processName: String?
        var pid: Int?
        switch query.source {
        case .app(let name), .process(let name):
            processName = name
            pid = try await runningPid(of: name, isApp: query.source == .app(name), on: serial, client: client)
        case .all, .reactNative:
            break
        }
        let script = LogcatCommand.script(window: query.window, pid: pid, reactNative: query.source == .reactNative)
        var parser = LogcatParser()
        let deliver: @MainActor (String) -> Void = { line in
            guard var entry = parser.parse(line) else { return }
            if let pid, entry.pid == pid {
                entry.process = processName
            }
            onEntry(entry)
        }
        log(.debug, "Reading logs on \(serial): \(script)")

        guard case .live(let duration) = query.window else {
            let result = try await client.shell(script, on: serial, timeout: .seconds(60), label: "logcat -d")
            guard result.status == 0 else {
                throw AndroidError.adbCommandFailed(serial: serial, command: "logcat -d", detail: Self.firstLine(result.stderrText) ?? "exit status \(result.status)")
            }
            result.stdoutText.split(separator: "\n", omittingEmptySubsequences: false).forEach { deliver(String($0)) }
            return
        }
        let opened = try await client.openService("shell,v2,raw:" + script, on: serial, timeout: .seconds(10))
        let shell = ShellStream(opened, serial: serial, label: "logcat")
        do {
            try await Self.follow(shell, until: duration.map { ContinuousClock.now + $0 }, serial: serial, deliver: deliver)
        } catch {
            await shell.close()
            throw error
        }
        await shell.close()
    }

    /// Reads in short slices so cancellation is noticed; ends at `end`, on cancellation or when logcat exits.
    private static func follow(_ shell: ShellStream, until end: ContinuousClock.Instant?, serial: String, deliver: @MainActor (String) -> Void) async throws {
        while !Task.isCancelled {
            let now = ContinuousClock.now
            if let end, now >= end { return }
            let slice = now + .milliseconds(250)
            do {
                switch try await shell.next(deadline: end.map { min($0, slice) } ?? slice) {
                case .line(let line):
                    deliver(line)
                case .exited(let status, let stdout, let stderr):
                    stdout.split(separator: "\n").forEach { deliver(String($0)) }
                    guard status == 0 else {
                        throw AndroidError.adbCommandFailed(serial: serial, command: "logcat", detail: firstLine(stderr) ?? "exit status \(status)")
                    }
                    return
                }
            } catch AdbConnectError.timedOut {
                continue
            }
        }
    }

    private func runningPid(of name: String, isApp: Bool, on serial: String, client: AdbClient) async throws -> Int {
        let result = try await client.shell(LogcatCommand.pidScript(for: name), on: serial)
        let firstWord = result.stdoutText.split(whereSeparator: \.isWhitespace).first
        guard result.status == 0, let pid = firstWord.flatMap({ Int($0) }) else {
            let noun = isApp ? "App" : "Process"
            let flag = isApp ? "--app" : "--process"
            throw AndroidError(.adbCommandFailed, "\(noun) \(name) is not running on \(serial). Launch it, or drop \(flag) to read all logs.")
        }
        return pid
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
