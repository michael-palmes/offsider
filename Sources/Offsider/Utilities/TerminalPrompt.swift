import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

/// Escape, Control-C or a closed terminal at a prompt. Nothing was saved.
struct PromptCancelled: Error {}

/// R at a menu or wait that offers a rescan: the caller looks again and redraws.
struct PromptRefresh: Error {}

/// No key for `idle` seconds, as when an agent drives the terminal and no person is there; nothing was saved.
struct PromptTimedOut: LocalizedError, UserFacingError, OffsiderFailure {
    let idle: TimeInterval
    let instead: String

    var reason: FailureReason { .usage }
    var waited: String { Self.duration(idle) }
    var userFacingDescription: String { "No key was pressed within \(waited), so the prompt closed and nothing changed. \(instead)" }
    var failureMessage: String { userFacingDescription }
    var errorDescription: String? { userFacingDescription }

    /// `60 s` or `10 minutes`.
    static func duration(_ seconds: TimeInterval) -> String {
        seconds >= 120 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60)) minutes" : "\(Int(seconds.rounded())) s"
    }
}

/// A block of questions on the terminal. Closing it erases every line it drew since the last `settle()`.
final class TerminalPrompt {
    let style: TerminalStyle
    /// The way round a terminal Offsider cannot use, for its errors.
    private let instead: String
    private let descriptor: Int32
    private let ownsDescriptor: Bool
    /// Seconds to wait for each key before giving up with `PromptTimedOut`.
    private let idle: TimeInterval
    private var original = termios()
    private var raw = termios()
    /// Echo and signals are off only while waiting for keys, so Control-C still stops a slow Keychain read.
    private var isRaw = false
    private var flushedTypeahead = false
    /// Finished rows drawn since the block began.
    private var rows = 0
    /// Rows of the line or menu still being edited.
    private var liveRows = 0
    /// The row of that live region the cursor is on.
    private var cursorRow = 0
    private var pending: [TerminalKey] = []
    /// Rows `close` leaves on screen.
    private var settled = 0

    /// Opens `/dev/tty`, or uses `descriptor` (a pseudo-terminal in tests).
    init(
        descriptor: Int32? = nil, instead: String = TerminalPrompt.pipeInstead, idle: TimeInterval = TerminalPrompt.defaultIdle,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.instead = instead
        self.idle = idle
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
            throw CLIError(errorDescription: "Could not open the terminal: \(reason). \(instead)", reason: .usage)
        }
        raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | INLCR | ISTRIP | BRKINT)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        style = TerminalStyle.detect(isTerminal: true, environment: environment)
    }

    static let pipeInstead = "Pass --stdin to pipe the answers in instead."

    /// How long any prompt waits for a key, so an agent driving a pseudo-terminal never hangs at one.
    static let defaultIdle: TimeInterval = 60

    /// Runs `body` in a block that is erased afterwards. A cancel says `cancelled` and exits 130.
    static func run<T>(
        cancelled: @autoclosure () -> String, instead: String = pipeInstead, descriptor: Int32? = nil, idle: TimeInterval = defaultIdle, keeps: Bool = false,
        _ body: (TerminalPrompt) throws -> T
    ) throws -> T {
        let prompt = try TerminalPrompt(descriptor: descriptor, instead: instead, idle: idle)
        do {
            let result = try body(prompt)
            if keeps { prompt.settle() }
            prompt.close()
            return result
        } catch is PromptCancelled {
            prompt.close(saying: prompt.style.dim(cancelled()))
            throw ExitCode(130)
        } catch {
            prompt.close()
            throw error
        }
    }

    /// Runs async `body` in a block that is erased afterwards, as `run` does.
    @MainActor
    static func runAsync<T>(
        cancelled: @autoclosure () -> String, instead: String = pipeInstead, descriptor: Int32? = nil, idle: TimeInterval = defaultIdle, keeps: Bool = false,
        _ body: @MainActor (TerminalPrompt) async throws -> T
    ) async throws -> T {
        let prompt = try TerminalPrompt(descriptor: descriptor, instead: instead, idle: idle)
        do {
            let result = try await body(prompt)
            if keeps { prompt.settle() }
            prompt.close()
            return result
        } catch is PromptCancelled {
            prompt.close(saying: prompt.style.dim(cancelled()))
            throw ExitCode(130)
        } catch {
            prompt.close()
            throw error
        }
    }

    /// The rows drawn so far, for `rewind(to:)`.
    var mark: Int { rows }

    /// Erases every line drawn since `mark`.
    func rewind(to mark: Int) {
        erase(to: max(mark, settled))
    }

    /// Keeps every line drawn so far on screen when the block closes, even on a cancel.
    func settle() {
        settled = rows
    }

    /// How wide to wrap prose: the terminal, at most 72 columns.
    var width: Int { PromptScreen.width(columns: terminalColumns) }

    /// The prompt's terminal, for a spinner drawn while it waits.
    var terminalDescriptor: Int32 { descriptor }

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
            let editor = LineEditor(masked: masked)
            let shown = try read(label, placeholder: placeholder, into: editor)
            let answer = editor.text
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

    /// Asks for a secret, then for it again. A mismatch clears both and starts over. The second entry never becomes a `String`.
    func askSecret(_ label: String, again: String, check: (String) -> String?) throws -> String {
        let start = rows
        var notice: String?
        while true {
            erase(to: start)
            let first = try ask(label, masked: true, notice: notice, check: check)
            let confirmation = LineEditor(masked: true)
            _ = try read(again, placeholder: nil, into: confirmation)
            if confirmation.matches(first) { return first }
            notice = PromptScreen.mismatch
        }
    }

    /// An arrow-key menu starting on `selected`, under a bold question with its controls beside it. The chosen row stays as a one-line reminder.
    func choose(_ question: String, options: [String], selected: Int = 0) throws -> Int {
        try choose(question, rows: options.map { MenuRow(nil, [$0]) }, selected: selected)
    }

    /// A menu of `rows` drawn by `TerminalUI.menu`; disabled rows are drawn but never chosen, and with none to choose only R and Q work.
    /// With `rescan`, R throws `PromptRefresh`; `quit` names what Q does. `keepsChoice` false erases the menu on Enter, for a caller that draws its own receipt.
    func choose(
        _ question: String?, step: String? = nil, rows: [MenuRow], selected: Int = 0, warning: String? = nil, notes: [String] = [],
        commands: [(label: String, command: String)] = [], rescan: Bool = false, quit: String = "quit", keepsChoice: Bool = true
    ) throws -> Int {
        try enterRaw()
        defer { leaveRaw() }
        let disabled = Set(rows.indices.filter { !rows[$0].enabled })
        var menu = ChoiceMenu(count: rows.count, selected: selected, disabled: disabled, refreshable: rescan)
        let controls = TerminalUI.Controls(choosing: rows.contains(where: \.enabled), rescan: rescan, quit: quit)
        write("\u{1B}[?25l")
        defer { write("\u{1B}[?25h") }
        let window = max((terminalRows ?? 24) - 8 - notes.count - commands.count, 3)
        func render() {
            draw(TerminalUI.menu(question, step: step, rows: rows, selected: menu.selected, controls: controls, warning: warning, notes: notes, commands: commands, width: width, window: window, style: style))
        }
        render()
        while true {
            switch try nextKey({ menu.apply($0) }) {
            case .chosen(let index):
                erase(to: self.rows)
                if keepsChoice { lines([TerminalUI.chosen(rows[index].columns.first ?? "", style: style)]) }
                return index
            case .cancelled:
                throw PromptCancelled()
            case .refresh:
                erase(to: self.rows)
                throw PromptRefresh()
            case .moving:
                if pending.isEmpty { render() }
            }
        }
    }

    /// A menu of `rows` where Space ticks and Enter takes every ticked row, starting with `ticked`. The menu is erased on Enter.
    func chooseMany(_ question: String, rows: [MenuRow], ticked: Set<Int>) throws -> [Int] {
        try enterRaw()
        defer { leaveRaw() }
        var menu = CheckMenu(count: rows.count, ticked: ticked)
        let controls = TerminalUI.Controls(ticking: true)
        write("\u{1B}[?25l")
        defer { write("\u{1B}[?25h") }
        func render() {
            var shown = rows
            for index in shown.indices { shown[index].columns.insert(TerminalUI.box(menu.ticked.contains(index)), at: 0) }
            draw(TerminalUI.menu(question, rows: shown, selected: menu.selected, controls: controls, width: width, style: style))
        }
        render()
        while true {
            switch try nextKey({ menu.apply($0) }) {
            case .chosen(let indices):
                erase(to: self.rows)
                return indices
            case .cancelled:
                throw PromptCancelled()
            case .moving:
                if pending.isEmpty { render() }
            }
        }
    }

    /// Reads one answer into `editor`, and returns its line as drawn: dots when masked.
    private func read(_ label: String, placeholder: String?, into editor: LineEditor) throws -> String {
        try enterRaw()
        defer { leaveRaw() }
        let prefix = style.cyan(label)
        func line() -> String { prefix + (editor.masked ? PromptScreen.dots(editor.length) : PromptScreen.visible(editor.text)) }
        func render() {
            if editor.isEmpty, let placeholder {
                draw(prefix + style.dim(placeholder), cursor: TerminalText.width(prefix))
            } else if editor.masked {
                draw(line())
            } else {
                draw(line(), cursor: TerminalText.width(prefix + PromptScreen.visible(editor.textBeforeCursor)))
            }
        }
        render()
        while true {
            switch try nextKey(editor.apply) {
            case .submitted:
                draw(line())
                commit()
                return line()
            case .cancelled:
                throw PromptCancelled()
            case .editing:
                if pending.isEmpty { render() }
            }
        }
    }

    /// Bytes read from the terminal at a time.
    static let readSize = 256

    /// Hands the next key to `use`, then zeroes any typed bytes it held.
    private func nextKey<T>(_ use: (TerminalKey) -> T) throws -> T {
        while pending.isEmpty {
            try awaitKey()
            let buffer = SecretBytes(capacity: Self.readSize)
            var result = 0
            buffer.append { result = Darwin.read(descriptor, $0.baseAddress, $0.count); return result }
            if result < 0, errno == EINTR || errno == EAGAIN { continue }
            guard result > 0 else { throw PromptCancelled() }
            while buffer.count < buffer.capacity, buffer.withBytes({ TerminalKey.endsMidSequence($0) }) {
                guard readAfterEscape(into: buffer) > 0 else { break }
            }
            pending = buffer.withBytes { TerminalKey.parse($0) }
        }
        var key = pending.removeFirst()
        defer { key.wipe() }
        return use(key)
    }

    /// Waits up to `idle` seconds for the terminal to have a byte to read. `select`, since macOS `poll` does not support `/dev/tty`.
    private func awaitKey() throws {
        guard descriptor < FD_SETSIZE else { return }
        let deadline = Date().addingTimeInterval(idle)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw PromptTimedOut(idle: idle, instead: instead) }
            var readable = fd_set()
            withUnsafeMutableBytes(of: &readable) { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
                let words = bytes.bindMemory(to: Int32.self)
                words[Int(descriptor) / 32] |= Int32(bitPattern: UInt32(1) << UInt32(descriptor % 32))
            }
            var wait = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - remaining.rounded(.down)) * 1_000_000))
            let ready = select(descriptor + 1, &readable, nil, nil, &wait)
            if ready > 0 { return }
            if ready == 0 { throw PromptTimedOut(idle: idle, instead: instead) }
            // EINTR goes round again; any other failure leaves the read to block as it did before.
            guard errno == EINTR else { return }
        }
    }

    /// Waits up to 100 ms for more of an arrow key. A termios timeout, since macOS `poll` does not support `/dev/tty`.
    private func readAfterEscape(into buffer: SecretBytes) -> Int {
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else { return 0 }
        var timed = settings
        withUnsafeMutableBytes(of: &timed.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }
        guard tcsetattr(descriptor, TCSANOW, &timed) == 0 else { return 0 }
        defer { _ = tcsetattr(descriptor, TCSANOW, &settings) }
        return buffer.append { Darwin.read(descriptor, $0.baseAddress, $0.count) }
    }

    /// Replaces the live region with `text`, moving back up from the cursor's row. `cursor` leaves it that many columns into a one-line `text`.
    private func draw(_ text: String, cursor: Int? = nil) {
        let columns = self.columns
        let up = cursorRow > 0 ? "\u{1B}[\(cursorRow)A" : ""
        let move = cursor.map { TerminalText.cursorMove(width: TerminalText.width(text), to: $0, columns: columns) }
        write(up + "\r\u{1B}[J" + text + (move?.sequence ?? ""))
        liveRows = TerminalText.rows(text, columns: columns)
        cursorRow = move?.row ?? liveRows - 1
    }

    /// Ends the live region. The cursor must be on its last row, as a draw without `cursor` leaves it.
    private func commit() {
        write("\n")
        rows += liveRows
        liveRows = 0
        cursorRow = 0
    }

    private func erase(to mark: Int) {
        let up = rows - mark + cursorRow
        write((up > 0 ? "\u{1B}[\(up)A" : "") + "\r\u{1B}[J")
        rows = mark
        liveRows = 0
        cursorRow = 0
    }

    private func enterRaw() throws {
        guard !isRaw else { return }
        TerminalRestore.arm(descriptor: descriptor, original: original, raw: raw)
        guard tcsetattr(descriptor, flushedTypeahead ? TCSANOW : TCSAFLUSH, &raw) == 0 else {
            TerminalRestore.disarm()
            throw CLIError(errorDescription: "Could not switch off echo on the terminal. \(instead)", reason: .usage)
        }
        flushedTypeahead = true
        isRaw = true
    }

    private func leaveRaw() {
        guard isRaw else { return }
        _ = tcsetattr(descriptor, TCSANOW, &original)
        TerminalRestore.disarm()
        isRaw = false
    }

    private func close(saying message: String? = nil) {
        erase(to: settled)
        if let message { write(message + "\n") }
        write("\u{1B}[?25h")
        for index in pending.indices { pending[index].wipe() }
        pending.removeAll()
        leaveRaw()
        _ = tcflush(descriptor, TCIFLUSH)
        if ownsDescriptor { Darwin.close(descriptor) }
    }

    private var columns: Int { terminalColumns ?? 80 }

    private var terminalRows: Int? {
        var size = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_row > 0 else { return nil }
        return Int(size.ws_row)
    }

    private var terminalColumns: Int? {
        var size = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
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
}

/// Puts the terminal back when another process ends or stops Offsider mid-prompt, and switches echo off again when it continues.
private enum TerminalRestore {
    nonisolated(unsafe) static var descriptor: Int32 = -1
    nonisolated(unsafe) static let saved = UnsafeMutablePointer<termios>.allocate(capacity: 1)
    nonisolated(unsafe) static let raw = UnsafeMutablePointer<termios>.allocate(capacity: 1)
    nonisolated(unsafe) static var previous: [(Int32, sigaction)] = []
    static let ending = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    static func arm(descriptor: Int32, original: termios, raw settings: termios) {
        saved.pointee = original
        raw.pointee = settings
        Self.descriptor = descriptor
        previous = ending.map { install(for: $0) { number in
            TerminalRestore.restore()
            Darwin.signal(number, SIG_DFL)
            raise(number)
        } }
        // Control-Z arrives as a key in raw mode, so this stop comes only from another process, such as kill -TSTP.
        previous.append(install(for: SIGTSTP) { number in
            TerminalRestore.restore()
            var handler = sigaction()
            var mask = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, number)
            sigaction(number, nil, &handler)
            Darwin.signal(number, SIG_DFL)
            pthread_sigmask(SIG_UNBLOCK, &mask, nil)
            raise(number)
            sigaction(number, &handler, nil)
        })
        // bash's fg hands the terminal back with echo on, as does a continue after SIGSTOP.
        previous.append(install(for: SIGCONT) { _ in
            if TerminalRestore.descriptor >= 0 { _ = tcsetattr(TerminalRestore.descriptor, TCSANOW, TerminalRestore.raw) }
        })
    }

    static func disarm() {
        for (number, var old) in previous { sigaction(number, &old, nil) }
        previous = []
        descriptor = -1
    }

    /// Async-signal-safe: the settings from before the prompt, and the cursor shown.
    private static func restore() {
        guard descriptor >= 0 else { return }
        let showCursor: StaticString = "\u{1B}[?25h"
        _ = tcsetattr(descriptor, TCSANOW, saved)
        _ = Darwin.write(descriptor, showCursor.utf8Start, showCursor.utf8CodeUnitCount)
    }

    private static func install(for number: Int32, _ handler: @convention(c) (Int32) -> Void) -> (Int32, sigaction) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = handler
        sigemptyset(&action.sa_mask)
        var old = sigaction()
        sigaction(number, &action, &old)
        return (number, old)
    }
}

/// A spinner on the terminal while `work` runs, drawn only when it takes longer than a moment, and erased when it ends.
enum TerminalSpinner {
    private final class State: @unchecked Sendable {
        var stopped = false
        var drawn = false
    }

    /// Draws on `terminal` (a copy of the prompt's descriptor) when given, else through the console, which draws for a person only.
    static func run<T>(_ label: String, terminal: Int32? = nil, _ work: () async throws -> T) async throws -> T {
        guard let terminal else { return try await Console.current.progress(label, work) }
        let descriptor = fcntl(terminal, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { return try await work() }
        let style = TerminalStyle.detect(isTerminal: true)
        let frames = TerminalUI.spinnerFrames(style: style)
        var size = winsize()
        let columns = ioctl(descriptor, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
        // One row at most, so the erase reaches all of it.
        let shown = TerminalText.width(label) + 3 < columns ? label : String(label.prefix(max(columns - 6, 1))) + style.ellipsis
        let queue = DispatchQueue(label: "offsider.spinner")
        let state = State()
        let start = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(80))
        timer.setEventHandler {
            guard !state.stopped else { return }
            let frame = frames[Int(Date().timeIntervalSince(start) * 12.5) % frames.count]
            let line = (state.drawn ? "" : "\u{1B}[?25l") + "\r\u{1B}[2K" + style.cyan(frame) + " " + style.dim(shown)
            state.drawn = true
            _ = line.withCString { Darwin.write(descriptor, $0, strlen($0)) }
        }
        timer.setCancelHandler { Darwin.close(descriptor) }
        timer.resume()
        defer {
            queue.sync {
                state.stopped = true
                if state.drawn { _ = "\r\u{1B}[2K\u{1B}[?25h".withCString { Darwin.write(descriptor, $0, strlen($0)) } }
            }
            timer.cancel()
        }
        return try await work()
    }
}
