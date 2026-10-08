import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

/// Escape, Control-C or a closed terminal at a prompt. Nothing was saved.
struct PromptCancelled: Error {}

/// A block of questions on the terminal with echo off. Closing it erases every line it drew.
final class TerminalPrompt {
    let style: TerminalStyle
    private let descriptor: Int32
    private let ownsDescriptor: Bool
    private var original = termios()
    /// Finished rows drawn since the block began.
    private var rows = 0
    /// Rows of the line or menu still being edited.
    private var liveRows = 0
    private var pending: [TerminalKey] = []

    /// Opens `/dev/tty`, or uses `descriptor` (a pseudo-terminal in tests).
    init(descriptor: Int32? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let descriptor {
            self.descriptor = descriptor
            ownsDescriptor = false
        } else {
            self.descriptor = open("/dev/tty", O_RDWR | O_CLOEXEC)
            ownsDescriptor = true
        }
        guard self.descriptor >= 0, tcgetattr(self.descriptor, &original) == 0 else {
            let reason = String(cString: strerror(errno))
            if ownsDescriptor, self.descriptor >= 0 { Darwin.close(self.descriptor) }
            throw CLIError(errorDescription: "Could not open the terminal: \(reason). Pass --stdin to pipe the answers in instead.", reason: .usage)
        }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | INLCR | ISTRIP | BRKINT)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        TerminalRestore.arm(descriptor: self.descriptor, original: original)
        guard tcsetattr(self.descriptor, TCSAFLUSH, &raw) == 0 else {
            TerminalRestore.disarm()
            if ownsDescriptor { Darwin.close(self.descriptor) }
            throw CLIError(errorDescription: "Could not switch off echo on the terminal. Pass --stdin to pipe the answers in instead.", reason: .usage)
        }
        style = TerminalStyle.detect(isTerminal: true, environment: environment)
    }

    /// Runs `body` in a block that is erased afterwards. A cancel says `cancelled` and exits 130.
    static func run<T>(cancelled: String, descriptor: Int32? = nil, _ body: (TerminalPrompt) throws -> T) throws -> T {
        let prompt = try TerminalPrompt(descriptor: descriptor)
        do {
            let result = try body(prompt)
            prompt.close()
            return result
        } catch is PromptCancelled {
            prompt.close(saying: prompt.style.dim(cancelled))
            throw ExitCode(130)
        } catch {
            prompt.close()
            throw error
        }
    }

    func lines(_ texts: [String]) {
        for text in texts {
            write(text + "\n")
            rows += TerminalText.rows(text, columns: columns)
        }
    }

    /// Asks for one line. `masked` shows a dot per character. While `check` names a problem, it shows it and asks again.
    func ask(_ label: String, masked: Bool = false, placeholder: String? = nil, notice: String? = nil, check: (String) -> String?) throws -> String {
        let start = rows
        var message = notice
        while true {
            erase(to: start)
            if let message { lines([style.yellow(message)]) }
            let (answer, shown) = try read(label, masked: masked, placeholder: placeholder)
            guard let problem = check(answer) else {
                if message != nil {
                    erase(to: start)
                    lines([shown])
                }
                return answer
            }
            message = problem
        }
    }

    /// Asks for a secret, then for it again. A mismatch clears both and starts over.
    func askSecret(_ label: String, again: String, check: (String) -> String?) throws -> String {
        let start = rows
        var notice: String?
        while true {
            erase(to: start)
            let first = try ask(label, masked: true, notice: notice, check: check)
            let (second, _) = try read(again, masked: true, placeholder: nil)
            if first == second { return first }
            notice = PromptScreen.mismatch
        }
    }

    /// An arrow-key menu. The chosen row stays as a one-line reminder.
    func choose(_ title: String, options: [String]) throws -> Int {
        var menu = ChoiceMenu(count: options.count)
        write("\u{1B}[?25l")
        defer { write("\u{1B}[?25h") }
        draw(PromptScreen.menu(title, options: options, selected: menu.selected, style: style))
        while true {
            switch menu.apply(try nextKey()) {
            case .chosen(let index):
                erase(to: rows)
                lines([PromptScreen.chosen(options[index], style: style)])
                return index
            case .cancelled:
                throw PromptCancelled()
            case .moving:
                if pending.isEmpty { draw(PromptScreen.menu(title, options: options, selected: menu.selected, style: style)) }
            }
        }
    }

    /// The answer, and its line as drawn: dots when `masked`.
    private func read(_ label: String, masked: Bool, placeholder: String?) throws -> (String, String) {
        var editor = LineEditor()
        defer { editor.wipe() }
        let prefix = style.cyan(label)
        func line() -> String { prefix + (masked ? PromptScreen.dots(editor.length) : editor.text) }
        func render() {
            if editor.bytes.isEmpty, let placeholder {
                draw(prefix + style.dim(placeholder) + "\u{1B}[\(TerminalText.width(placeholder))D")
            } else {
                draw(line())
            }
        }
        render()
        while true {
            switch editor.apply(try nextKey()) {
            case .submitted:
                draw(line())
                commit()
                return (editor.text, line())
            case .cancelled:
                throw PromptCancelled()
            case .editing:
                if pending.isEmpty { render() }
            }
        }
    }

    private func nextKey() throws -> TerminalKey {
        while pending.isEmpty {
            var buffer = [UInt8](repeating: 0, count: 256)
            defer { Self.wipe(&buffer) }
            var count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw PromptCancelled() }
            if buffer[count - 1] == 0x1B, count < buffer.count {
                count += readAfterEscape(into: &buffer, at: count)
            }
            pending = TerminalKey.parse(Array(buffer[..<count]))
        }
        return pending.removeFirst()
    }

    /// Waits up to 100 ms for the rest of an arrow key. A termios timeout, since macOS `poll` does not support `/dev/tty`.
    private func readAfterEscape(into buffer: inout [UInt8], at offset: Int) -> Int {
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else { return 0 }
        var timed = settings
        withUnsafeMutableBytes(of: &timed.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }
        guard tcsetattr(descriptor, TCSANOW, &timed) == 0 else { return 0 }
        defer { _ = tcsetattr(descriptor, TCSANOW, &settings) }
        return max(0, buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + offset, $0.count - offset) })
    }

    /// Replaces the live region with `text`, moving back over every row the last draw took.
    private func draw(_ text: String) {
        let up = liveRows > 1 ? "\u{1B}[\(liveRows - 1)A" : ""
        write(up + "\r\u{1B}[J" + text)
        liveRows = TerminalText.rows(text, columns: columns)
    }

    private func commit() {
        write("\n")
        rows += liveRows
        liveRows = 0
    }

    private func erase(to mark: Int) {
        let up = rows - mark + max(liveRows - 1, 0)
        write((up > 0 ? "\u{1B}[\(up)A" : "") + "\r\u{1B}[J")
        rows = mark
        liveRows = 0
    }

    private func close(saying message: String? = nil) {
        erase(to: 0)
        if let message { write(message + "\n") }
        write("\u{1B}[?25h")
        pending.removeAll()
        _ = tcsetattr(descriptor, TCSAFLUSH, &original)
        TerminalRestore.disarm()
        if ownsDescriptor { Darwin.close(descriptor) }
    }

    private var columns: Int {
        var size = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }

    private func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }

    private static func wipe(_ buffer: inout [UInt8]) {
        buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }
}

/// Puts the terminal back when another process stops Offsider mid-prompt, then lets the signal through.
private enum TerminalRestore {
    nonisolated(unsafe) static var descriptor: Int32 = -1
    nonisolated(unsafe) static let saved = UnsafeMutablePointer<termios>.allocate(capacity: 1)
    nonisolated(unsafe) static var previous: [(Int32, sigaction)] = []
    static let signals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    static func arm(descriptor: Int32, original: termios) {
        saved.pointee = original
        Self.descriptor = descriptor
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { number in
            if TerminalRestore.descriptor >= 0 {
                let showCursor: StaticString = "\u{1B}[?25h"
                _ = tcsetattr(TerminalRestore.descriptor, TCSANOW, TerminalRestore.saved)
                _ = Darwin.write(TerminalRestore.descriptor, showCursor.utf8Start, showCursor.utf8CodeUnitCount)
            }
            Darwin.signal(number, SIG_DFL)
            raise(number)
        }
        sigemptyset(&action.sa_mask)
        previous = signals.map { number in
            var old = sigaction()
            sigaction(number, &action, &old)
            return (number, old)
        }
    }

    static func disarm() {
        for (number, var old) in previous { sigaction(number, &old, nil) }
        previous = []
        descriptor = -1
    }
}

/// A spinner on the terminal while `work` runs, drawn only when it takes longer than a moment.
enum TerminalSpinner {
    private final class State: @unchecked Sendable {
        var stopped = false
    }

    static func run<T>(_ label: String, _ work: () async throws -> T) async throws -> T {
        let descriptor = open("/dev/tty", O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return try await work() }
        let style = TerminalStyle.detect(isTerminal: true)
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let queue = DispatchQueue(label: "offsider.spinner")
        let state = State()
        let start = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(80))
        timer.setEventHandler {
            guard !state.stopped else { return }
            let frame = frames[Int(Date().timeIntervalSince(start) * 12.5) % frames.count]
            let line = "\r\u{1B}[K" + style.cyan(frame) + " " + style.dim(label)
            _ = line.withCString { Darwin.write(descriptor, $0, strlen($0)) }
        }
        timer.setCancelHandler { Darwin.close(descriptor) }
        timer.resume()
        defer {
            queue.sync {
                state.stopped = true
                _ = "\r\u{1B}[K".withCString { Darwin.write(descriptor, $0, strlen($0)) }
            }
            timer.cancel()
        }
        return try await work()
    }
}
