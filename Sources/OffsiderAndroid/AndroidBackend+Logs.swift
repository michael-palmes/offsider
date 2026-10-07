import Foundation
import OffsiderCore

extension AndroidBackend: LogReading {
    /// `logcat -d` for history, or `logcat` over a shell stream until the window ends or the task is cancelled.
    public func readLogs(_ query: LogQuery, on id: DeviceID, onEntry: @escaping @MainActor (LogEntry) -> Void, onNote: @escaping @MainActor (LogNote) -> Void) async throws {
        guard query.predicate == nil else {
            throw AndroidError(.notSupported, "--predicate is iOS only; on Android use --app, --rn or --grep.")
        }
        try await prepare()
        let serial = id.rawValue
        let client = try requireClient()
        let script = LogcatCommand.script(window: query.window, source: query.source)
        var stream = LogcatStream(source: query.source, serial: serial)
        let deliver: @MainActor (String) throws -> Void = { line in
            let entry = try stream.consume(line)
            if let note = stream.note {
                stream.note = nil
                onNote(note)
            }
            if let entry { onEntry(entry) }
        }
        log(.debug, "Reading logs on \(serial): \(script)")

        guard case .live(let duration) = query.window else {
            let result = try await client.shell(script, on: serial, timeout: .seconds(60), label: "logcat -d")
            for line in result.stdoutText.split(separator: "\n", omittingEmptySubsequences: false) {
                try deliver(String(line))
            }
            guard result.status == 0 else {
                throw AndroidError.adbCommandFailed(serial: serial, command: "logcat -d", detail: Self.firstLine(result.stderrText) ?? "exit status \(result.status)")
            }
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
    private static func follow(_ shell: ShellStream, until end: ContinuousClock.Instant?, serial: String, deliver: @MainActor (String) throws -> Void) async throws {
        while !Task.isCancelled {
            let now = ContinuousClock.now
            if let end, now >= end { return }
            let slice = now + .milliseconds(250)
            do {
                switch try await shell.next(deadline: end.map { min($0, slice) } ?? slice) {
                case .line(let line):
                    try deliver(line)
                case .exited(let status, let stdout, let stderr):
                    for line in stdout.split(separator: "\n") { try deliver(String(line)) }
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

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
