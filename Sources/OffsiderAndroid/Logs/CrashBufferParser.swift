import Foundation

/// Reads `logcat -b crash` for what stopped a process: the exception class or the signal, never message text, which can hold user data.
enum CrashBufferParser {
    static func command(pid: Int) -> String {
        "logcat -b crash -d -v threadtime --pid=\(pid)"
    }

    /// The crash buffer since `since`, from 5 s before it in case the device's clock runs behind the Mac's.
    static func command(since: Date) -> String {
        // A bare number is a line count to logcat, so the time carries its fraction.
        "logcat -b crash -d -v threadtime -T \(Int((since.timeIntervalSince1970 - 5).rounded(.down))).000"
    }

    /// The cause of `package`'s newest crash: the pid its `Process:` line or a native crash's `pid <n> (<package>)` names, then that pid's lines.
    static func cause(in output: String, package: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
        var crashed: Substring?
        for line in lines {
            guard let message = message(of: line) else { continue }
            if message.hasPrefix("Process: \(package), PID: ") {
                crashed = message.dropFirst("Process: \(package), PID: ".count).prefix { $0.isNumber }
            } else if message.hasPrefix("Fatal signal"), let pid = nativePID(message, package: package) {
                crashed = pid
            }
        }
        guard let crashed, !crashed.isEmpty else { return nil }
        return cause(in: lines.filter { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(2).first == crashed }.joined(separator: "\n"))
    }

    /// `signal 11 (SIGSEGV)` for a native crash, else the class of the first exception after `FATAL EXCEPTION`, such as `java.lang.IllegalStateException`.
    static func cause(in output: String) -> String? {
        var afterFatal = false
        var exception: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let message = message(of: line) else { continue }
            if let signal = signal(in: message) { return signal }
            if message.hasPrefix("FATAL EXCEPTION") {
                afterFatal = true
            } else if afterFatal, exception == nil {
                exception = exceptionClass(message)
            }
        }
        return exception
    }

    private static let linePattern = try! NSRegularExpression(pattern: #"^\s*\d+-\d+\s+\d+:\d+:\d+\.\d+\s+\d+\s+\d+\s+[VDIWEFA]\s+[^:]*?\s*:\s(.*)$"#)
    private static let signalPattern = try! NSRegularExpression(pattern: #"^(?:Fatal )?signal (\d+) \((SIG[A-Z0-9]+)\)"#)
    private static let classPattern = try! NSRegularExpression(pattern: #"^((?:[A-Za-z_$][A-Za-z0-9_$]*\.)+[A-Za-z_$][A-Za-z0-9_$]*)(?::|$)"#)

    private static func message(of line: Substring) -> String? {
        let text = String(line)
        guard let match = linePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// `4100` from a libc line ending `pid 4100 (com.example.app)`.
    private static func nativePID(_ message: String, package: String) -> Substring? {
        guard let range = message.range(of: " (\(package))", options: .backwards) else { return nil }
        let before = message[..<range.lowerBound]
        let count = before.reversed().prefix(while: \.isNumber).count
        guard count > 0, before.dropLast(count).hasSuffix("pid ") else { return nil }
        return before.suffix(count)
    }

    private static func signal(in message: String) -> String? {
        guard let match = signalPattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let number = Range(match.range(at: 1), in: message), let name = Range(match.range(at: 2), in: message) else { return nil }
        return "signal \(message[number]) (\(message[name]))"
    }

    private static func exceptionClass(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        guard let match = classPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[range])
    }
}
