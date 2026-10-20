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
    /// Wakes the wait for a key when the terminal changes size; nil when nothing reports that.
    private let resize: ResizeNotifier?
    private var original = termios()
    private var raw = termios()
    /// Echo and signals are off only while waiting for keys, so Control-C still stops a slow Keychain read.
    private var isRaw = false
    private var flushedTypeahead = false
    /// Every line drawn since the block began, by width, so a resize can count its rows again.
    private var block = DrawnBlock()
    private var pending: [TerminalKey] = []
    /// When the wait for the next key gives up; a redraw for a resize never moves it.
    private var deadline: Date?
    /// The line `close` erases back to.
    private var settled = 0

    /// Opens `/dev/tty`, whose resizes come by SIGWINCH, or uses `descriptor` (a pseudo-terminal in tests) and `resize`.
    init(
        descriptor: Int32? = nil, instead: String = TerminalPrompt.pipeInstead, idle: TimeInterval = TerminalPrompt.defaultIdle,
        environment: [String: String] = ProcessInfo.processInfo.environment, resize: ResizeNotifier? = nil
    ) throws {
        self.instead = instead
        self.idle = idle
        if let descriptor {
            self.descriptor = descriptor
            ownsDescriptor = false
            self.resize = resize
        } else {
            self.descriptor = open("/dev/tty", O_RDWR | O_CLOEXEC)
            ownsDescriptor = true
            self.resize = resize ?? ResizeNotifier.signal
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
        resize: ResizeNotifier? = nil, _ body: (TerminalPrompt) throws -> T
    ) throws -> T {
        let prompt = try TerminalPrompt(descriptor: descriptor, instead: instead, idle: idle, resize: resize)
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

    /// Where the block has got to, for `rewind(to:)`.
    var mark: Int { block.count }

    /// Erases every line drawn since `mark`.
    func rewind(to mark: Int) {
        erase(to: max(mark, settled))
    }

    /// Keeps every line drawn so far on screen when the block closes, even on a cancel.
    func settle() {
        settled = block.count
    }

    /// How wide to wrap prose: the terminal, at most 72 columns.
    var width: Int { PromptScreen.width(columns: terminalColumns) }

    /// The prompt's terminal, for a spinner drawn while it waits.
    var terminalDescriptor: Int32 { descriptor }

    func lines(_ texts: [String]) {
        for text in texts {
            write(text + "\n")
            block.finish(text)
        }
    }

    /// Asks for one line. `masked` shows a dot per character. While `check` names a problem, it shows it and asks again.
    func ask(_ label: String, masked: Bool = false, placeholder: String? = nil, notice: String? = nil, check: (String) -> String?) throws -> String {
        let start = block.count
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
        let start = block.count
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
    /// `filterable` lets `/` filter a list longer than nine rows or the screen; the index returned is still the row's in `rows`.
    func choose(
        _ question: String?, step: String? = nil, rows: [MenuRow], selected: Int = 0, warning: String? = nil, notes: [String] = [],
        commands: [(label: String, command: String)] = [], rescan: Bool = false, quit: String = "quit", keepsChoice: Bool = true, filterable: Bool = false
    ) throws -> Int {
        try enterRaw()
        defer { leaveRaw() }
        let disabled = Set(rows.indices.filter { !rows[$0].enabled })
        let search = filterable ? rows.map { $0.columns.joined(separator: " ") } : nil
        var menu = ChoiceMenu(count: rows.count, selected: selected, disabled: disabled, refreshable: rescan, search: search)
        let choosing = rows.contains(where: \.enabled)
        write("\u{1B}[?25l")
        defer { write("\u{1B}[?25h") }
        func render() {
            let room = (terminalRows ?? 24) - 8 - notes.count - commands.count
            menu.window = max(room, 3)
            let filtering = menu.query != nil
            let controls = TerminalUI.Controls(choosing: choosing, rescan: rescan, quit: quit, filter: menu.offersFilter, filtering: filtering)
            draw(TerminalUI.menu(
                question, step: step, rows: rows, selected: menu.selected, controls: controls, warning: warning, notes: notes, commands: commands, width: width,
                window: max(room - (filtering ? 1 : 0), 3), style: style, query: menu.query, shown: filtering ? menu.shown : nil
            ))
        }
        render()
        while true {
            switch try nextKey({ menu.apply($0) }) {
            case .chosen(let index):
                erase(to: block.count)
                if keepsChoice { lines([TerminalUI.chosen(rows[index].columns.first ?? "", style: style)]) }
                return index
            case .cancelled:
                throw PromptCancelled()
            case .refresh:
                erase(to: block.count)
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
                erase(to: block.count)
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

    /// Hands the next key to `use`, then zeroes any typed bytes it held. A resize while waiting comes as `.resize`.
    private func nextKey<T>(_ use: (TerminalKey) -> T) throws -> T {
        while pending.isEmpty {
            let until = deadline ?? Date().addingTimeInterval(idle)
            deadline = until
            if try awaitKey(until: until) {
                pending = [.resize]
                break
            }
            let buffer = SecretBytes(capacity: Self.readSize)
            var result = 0
            buffer.append { result = Darwin.read(descriptor, $0.baseAddress, $0.count); return result }
            if result < 0, errno == EINTR || errno == EAGAIN { continue }
            guard result > 0 else { throw PromptCancelled() }
            deadline = nil
            while buffer.count < buffer.capacity, buffer.withBytes({ TerminalKey.endsMidSequence($0) }) {
                guard readAfterEscape(into: buffer) > 0 else { break }
            }
            pending = buffer.withBytes { TerminalKey.parse($0) }
        }
        var key = pending.removeFirst()
        defer { key.wipe() }
        return use(key)
    }

    /// Waits until `deadline` for the terminal to have a byte to read, and says true when a resize woke it first.
    /// `select`, since macOS `poll` does not support `/dev/tty`.
    private func awaitKey(until deadline: Date) throws -> Bool {
        guard descriptor < FD_SETSIZE else { return false }
        let wake = resize.map(\.readEnd).flatMap { $0 >= 0 && $0 < FD_SETSIZE ? $0 : nil }
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw PromptTimedOut(idle: idle, instead: instead) }
            var readable = fd_set()
            Self.add(descriptor, to: &readable)
            if let wake { Self.add(wake, to: &readable) }
            var wait = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - remaining.rounded(.down)) * 1_000_000))
            let ready = select(max(descriptor, wake ?? -1) + 1, &readable, nil, nil, &wait)
            if ready > 0 {
                if let wake, Self.holds(wake, readable), resize?.drain() == true { return true }
                if Self.holds(descriptor, readable) { return false }
                continue
            }
            if ready == 0 { throw PromptTimedOut(idle: idle, instead: instead) }
            // EINTR goes round again; any other failure leaves the read to block as it did before.
            guard errno == EINTR else { return false }
        }
    }

    private static func add(_ descriptor: Int32, to set: inout fd_set) {
        withUnsafeMutableBytes(of: &set) { bytes in
            bytes.bindMemory(to: Int32.self)[Int(descriptor) / 32] |= Int32(bitPattern: UInt32(1) << UInt32(descriptor % 32))
        }
    }

    private static func holds(_ descriptor: Int32, _ set: fd_set) -> Bool {
        withUnsafeBytes(of: set) { bytes in
            bytes.load(fromByteOffset: Int(descriptor) / 32 * 4, as: Int32.self) & Int32(bitPattern: UInt32(1) << UInt32(descriptor % 32)) != 0
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

    /// Replaces the live region with `text`, climbing from the cursor over the rows the last one fills now, so a resize redraws cleanly.
    /// `cursor` leaves the cursor that many columns into a one-line `text`.
    private func draw(_ text: String, cursor: Int? = nil) {
        let columns = self.columns
        let up = block.climb(to: block.count, columns: columns)
        let move = cursor.map { TerminalText.cursorMove(width: TerminalText.width(text), to: $0, columns: columns) }
        write((up > 0 ? "\u{1B}[\(up)A" : "") + "\r\u{1B}[J" + text + (move?.sequence ?? ""))
        block.show(text, cursor: cursor)
    }

    /// Ends the live region. The cursor must be on its last row, as a draw without `cursor` leaves it.
    private func commit() {
        write("\n")
        block.commit()
    }

    private func erase(to mark: Int) {
        let up = block.climb(to: mark, columns: columns)
        write((up > 0 ? "\u{1B}[\(up)A" : "") + "\r\u{1B}[J")
        block.drop(from: mark)
    }

    private func enterRaw() throws {
        guard !isRaw else { return }
        TerminalRestore.arm(descriptor: descriptor, original: original, raw: raw, resize: resize)
        guard tcsetattr(descriptor, flushedTypeahead ? TCSANOW : TCSAFLUSH, &raw) == 0 else {
            TerminalRestore.disarm(resize: hearsSignal)
            throw CLIError(errorDescription: "Could not switch off echo on the terminal. \(instead)", reason: .usage)
        }
        flushedTypeahead = true
        isRaw = true
    }

    private func leaveRaw() {
        deadline = nil
        guard isRaw else { return }
        _ = tcsetattr(descriptor, TCSANOW, &original)
        TerminalRestore.disarm(resize: hearsSignal)
        isRaw = false
    }

    private var hearsSignal: Bool { resize?.hearsSignal == true }

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

/// What a prompt has drawn since its block began, kept as each line's width: a terminal that reflows on a resize folds
/// every line again, so its rows are counted afresh at whatever width the terminal has now, `max(1, ⌈width / columns⌉)` each.
struct DrawnBlock: Equatable {
    /// Finished lines.
    private(set) var lines: [Int] = []
    /// The region still being redrawn, a width per line; empty when there is none.
    private(set) var live: [Int] = []
    /// How far into the live region's last line the cursor waits; nil at its end.
    private(set) var cursor: Int?

    /// Finished lines so far: an opaque mark to erase back to.
    var count: Int { lines.count }

    static func rows(_ widths: some Sequence<Int>, columns: Int) -> Int {
        let columns = max(columns, 1)
        return widths.reduce(0) { $0 + max(1, ($1 + columns - 1) / columns) }
    }

    mutating func finish(_ text: String) {
        lines += Self.widths(text)
    }

    mutating func show(_ text: String, cursor: Int?) {
        live = Self.widths(text)
        self.cursor = cursor
    }

    mutating func commit() {
        lines += live
        live = []
        cursor = nil
    }

    mutating func drop(from mark: Int) {
        lines.removeSubrange(Self.clamp(mark, lines.count)...)
        live = []
        cursor = nil
    }

    /// Rows from the cursor up to the first row of line `mark` at `columns`, never above the block's own first row.
    func climb(to mark: Int, columns: Int) -> Int {
        var rows = Self.rows(lines[Self.clamp(mark, lines.count)...], columns: columns)
        guard let last = live.last else { return rows }
        rows += Self.rows(live.dropLast(), columns: columns)
        return rows + (cursor.map { TerminalText.cursorMove(width: last, to: $0, columns: columns).row } ?? Self.rows([last], columns: columns) - 1)
    }

    private static func clamp(_ mark: Int, _ count: Int) -> Int {
        min(max(mark, 0), count)
    }

    private static func widths(_ text: String) -> [Int] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { TerminalText.width(String($0)) }
    }
}

/// Wakes a prompt waiting for a key when its terminal changes size: one byte down a non-blocking, close-on-exec pipe.
final class ResizeNotifier: @unchecked Sendable {
    /// The pipe SIGWINCH writes to, open for the life of the process so its handler never writes to a closed descriptor.
    static let signal = ResizeNotifier(hearsSignal: true)

    let readEnd: Int32
    let writeEnd: Int32
    /// True only for `signal`: a prompt using it hooks SIGWINCH while it waits for a key.
    let hearsSignal: Bool

    /// A pipe of its own, which a test posts to instead of raising a signal.
    convenience init?() {
        self.init(hearsSignal: false)
    }

    private init?(hearsSignal: Bool) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        for end in ends {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
        }
        readEnd = ends[0]
        writeEnd = ends[1]
        self.hearsSignal = hearsSignal
    }

    /// What SIGWINCH does, for a test to call instead; a full pipe already holds a wake.
    func post() {
        var byte: UInt8 = 1
        _ = Darwin.write(writeEnd, &byte, 1)
    }

    /// Empties the pipe, and says whether it held anything.
    func drain() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64)
        var drained = false
        while Darwin.read(readEnd, &buffer, buffer.count) > 0 { drained = true }
        return drained
    }

    deinit {
        Darwin.close(readEnd)
        Darwin.close(writeEnd)
    }
}

/// Puts the terminal back when another process ends or stops Offsider mid-prompt, switches echo off again when it continues,
/// and turns SIGWINCH into a byte on the prompt's resize pipe.
private enum TerminalRestore {
    nonisolated(unsafe) static var descriptor: Int32 = -1
    /// The pipe SIGWINCH writes to; -1 while no prompt waits on it.
    nonisolated(unsafe) static var resize: Int32 = -1
    nonisolated(unsafe) static let saved = UnsafeMutablePointer<termios>.allocate(capacity: 1)
    nonisolated(unsafe) static let raw = UnsafeMutablePointer<termios>.allocate(capacity: 1)
    /// Each hooked signal's action from before the first prompt hooked it, and how many prompts hook it now, so overlapping prompts restore it once.
    nonisolated(unsafe) static var previous: [Int32: (action: sigaction, holders: Int)] = [:]
    static let lock = NSLock()
    static let ending = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    static func arm(descriptor: Int32, original: termios, raw settings: termios, resize notifier: ResizeNotifier?) {
        lock.withLock {
            saved.pointee = original
            raw.pointee = settings
            Self.descriptor = descriptor
            for number in ending {
                hook(number) { number in
                    TerminalRestore.restore()
                    Darwin.signal(number, SIG_DFL)
                    raise(number)
                }
            }
            // Control-Z arrives as a key in raw mode, so this stop comes only from another process, such as kill -TSTP.
            hook(SIGTSTP) { number in
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
            }
            // bash's fg hands the terminal back with echo on, as does a continue after SIGSTOP.
            hook(SIGCONT) { _ in
                if TerminalRestore.descriptor >= 0 { _ = tcsetattr(TerminalRestore.descriptor, TCSANOW, TerminalRestore.raw) }
            }
            guard let notifier, notifier.hearsSignal else { return }
            resize = notifier.writeEnd
            // SA_RESTART, so a resize never fails another thread's read or write with EINTR; the byte still wakes the prompt's select.
            hook(SIGWINCH, flags: SA_RESTART) { _ in
                let saved = errno
                var byte: UInt8 = 1
                _ = Darwin.write(TerminalRestore.resize, &byte, 1)
                errno = saved
            }
        }
    }

    /// `resize` says whether the matching `arm` hooked SIGWINCH.
    static func disarm(resize hooked: Bool) {
        lock.withLock {
            for number in ending + [SIGTSTP, SIGCONT] + (hooked ? [SIGWINCH] : []) { release(number) }
            descriptor = -1
            if previous[SIGWINCH] == nil { resize = -1 }
        }
    }

    /// Call with the lock held.
    private static func hook(_ number: Int32, flags: Int32 = 0, _ handler: @convention(c) (Int32) -> Void) {
        if let held = previous[number] {
            previous[number] = (held.action, held.holders + 1)
        } else {
            previous[number] = (install(for: number, flags: flags, handler), 1)
        }
    }

    /// Call with the lock held.
    private static func release(_ number: Int32) {
        guard var held = previous[number] else { return }
        guard held.holders <= 1 else {
            previous[number] = (held.action, held.holders - 1)
            return
        }
        sigaction(number, &held.action, nil)
        previous[number] = nil
    }

    /// Async-signal-safe: the settings from before the prompt, and the cursor shown.
    private static func restore() {
        guard descriptor >= 0 else { return }
        let showCursor: StaticString = "\u{1B}[?25h"
        _ = tcsetattr(descriptor, TCSANOW, saved)
        _ = Darwin.write(descriptor, showCursor.utf8Start, showCursor.utf8CodeUnitCount)
    }

    private static func install(for number: Int32, flags: Int32, _ handler: @convention(c) (Int32) -> Void) -> sigaction {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = handler
        action.sa_flags = flags
        sigemptyset(&action.sa_mask)
        var old = sigaction()
        sigaction(number, &action, &old)
        return old
    }
}

/// A spinner on the terminal while `work` runs, drawn only when it takes longer than a moment, and erased when it ends.
enum TerminalSpinner {
    private final class State: @unchecked Sendable {
        var stopped = false
        var drawn = false
        /// Columns the last frame filled.
        var width = 0
    }

    /// Draws on `terminal` (a copy of the prompt's descriptor) when given, else through the console, which draws for a person only.
    /// Each frame measures the terminal again, so a resize mid-spin never leaves a stray row.
    static func run<T>(_ label: String, terminal: Int32? = nil, _ work: () async throws -> T) async throws -> T {
        guard let terminal else { return try await Console.current.progress(label, work) }
        let descriptor = fcntl(terminal, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { return try await work() }
        let style = TerminalStyle.detect(isTerminal: true)
        let frames = TerminalUI.spinnerFrames(style: style)
        let queue = DispatchQueue(label: "offsider.spinner")
        let state = State()
        let start = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(80))
        timer.setEventHandler {
            guard !state.stopped else { return }
            let glyph = frames[Int(Date().timeIntervalSince(start) * 12.5) % frames.count]
            let frame = Self.frame(glyph, label: label, columns: TerminalSize.columns(of: descriptor) ?? 80, after: state.width, style: style)
            let line = (state.drawn ? "" : "\u{1B}[?25l") + frame.text
            state.drawn = true
            state.width = frame.width
            _ = line.withCString { Darwin.write(descriptor, $0, strlen($0)) }
        }
        timer.setCancelHandler { Darwin.close(descriptor) }
        timer.resume()
        defer {
            queue.sync {
                state.stopped = true
                guard state.drawn else { return }
                let clear = Self.clear(state.width, columns: TerminalSize.columns(of: descriptor) ?? 80) + "\u{1B}[?25h"
                _ = clear.withCString { Darwin.write(descriptor, $0, strlen($0)) }
            }
            timer.cancel()
        }
        return try await work()
    }

    /// One frame at `columns`: back over every row the last frame (`previous` columns wide) fills now, then the glyph and the label cut to `columns - 4`.
    static func frame(_ glyph: String, label: String, columns: Int, after previous: Int, style: TerminalStyle) -> (text: String, width: Int) {
        let shown = TerminalText.truncate(TerminalText.line(label, cap: nil, keepsTab: false), to: max(columns - 4, 1), ellipsis: style.ellipsis)
        return (clear(previous, columns: columns) + style.cyan(glyph) + " " + style.dim(shown), TerminalText.width(glyph) + 1 + TerminalText.width(shown))
    }

    /// From the end of a frame `width` columns wide, up to its first row at `columns`, and clear from there down.
    static func clear(_ width: Int, columns: Int) -> String {
        let up = DrawnBlock.rows([width], columns: columns) - 1
        return (up > 0 ? "\u{1B}[\(up)A" : "") + "\r\u{1B}[J"
    }
}
