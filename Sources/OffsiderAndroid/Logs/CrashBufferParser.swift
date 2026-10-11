import Foundation

/// Reads `logcat -b crash` for what stopped a process: the exception class or the signal, never message text, which can hold user data.
enum CrashBufferParser {
    static func command(pid: Int) -> String {
        "logcat -b crash -d -v threadtime --pid=\(pid)"
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
