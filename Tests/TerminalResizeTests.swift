import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Terminal resize", .serialized)
struct TerminalResizeTests {
    @Test("rows are counted again at the new width: a line takes ⌈width / columns⌉ rows, an empty line one")
    func recount() {
        #expect(DrawnBlock.rows([28, 0, 50, 10], columns: 80) == 4)
        #expect(DrawnBlock.rows([28, 0, 50, 10], columns: 20) == 7)
        #expect(DrawnBlock.rows([40], columns: 20) == 2)
        #expect(DrawnBlock.rows([41], columns: 20) == 3)
        #expect(DrawnBlock.rows([5], columns: 0) == 5)
    }

    @Test("the climb runs from the cursor to a mark's first row at the width the terminal has now, and never above the block")
    func climb() {
        var block = DrawnBlock()
        block.finish(String(repeating: "h", count: 30))
        let mark = block.count
        block.finish("")
        block.show("Pick one\n" + String(repeating: "r", count: 25), cursor: nil)
        #expect(block.climb(to: block.count, columns: 80) == 1)
        #expect(block.climb(to: mark, columns: 80) == 2)
        #expect(block.climb(to: 0, columns: 80) == 3)
        #expect(block.climb(to: 0, columns: 10) == 3 + 1 + 1 + 2)
        #expect(block.climb(to: -4, columns: 80) == 3)
        #expect(block.climb(to: 99, columns: 80) == 1)
        block.commit()
        #expect(block.count == 4)
        #expect(block.climb(to: 2, columns: 10) == 1 + 3)
        block.drop(from: mark)
        #expect(block.count == mark)
        #expect(block.climb(to: 0, columns: 10) == 3)
    }

    @Test("a cursor placed mid-line counts the rows above it in that line, at the new width")
    func cursorRow() {
        var block = DrawnBlock()
        block.show("👤 qa-admin", cursor: 3)
        #expect(block.climb(to: 0, columns: 80) == 0)
        block.show("👤 qa-admin", cursor: 7)
        #expect(block.climb(to: 0, columns: 5) == 1)
        block.show("👤 qa-admin", cursor: 11)
        #expect(block.climb(to: 0, columns: 5) == 2)
    }

    @Test("a spinner frame cuts its label to four short of the width, and first climbs every row the last frame fills now")
    func spinnerFrame() {
        let label = "Looking for devices on every simulator"
        let first = TerminalSpinner.frame("⠋", label: label, columns: 20, after: 0, style: .plain)
        #expect(first.text == "\r\u{1B}[J⠋ Looking for dev…")
        #expect(first.width == 18)
        let narrowed = TerminalSpinner.frame("⠙", label: label, columns: 20, after: 40, style: .plain)
        #expect(narrowed.text.hasPrefix("\u{1B}[1A\r\u{1B}[J⠙ "))
        let ascii = TerminalSpinner.frame("|", label: label, columns: 12, after: 30, style: TerminalStyle(colours: false, ascii: true))
        #expect(ascii.text == "\u{1B}[2A\r\u{1B}[J| Looki...")
        #expect(TerminalSpinner.clear(18, columns: 80) == "\r\u{1B}[J")
        #expect(TerminalSpinner.clear(0, columns: 80) == "\r\u{1B}[J")
    }

    @Test("a resize redraws the menu, climbing the rows the old draw fills at the new width; a widen climbs fewer")
    func menuRedrawsOnResize() throws {
        let terminal = try PseudoTerminal()
        let resize = try #require(ResizeNotifier())
        terminal.resize(columns: 80, rows: 24)
        let long = "A second option long enough to fold twice over"
        let seen = Recorded()
        Thread.detachNewThread {
            guard terminal.wait(forOutput: long) else { return }
            terminal.resize(columns: 20, rows: 24)
            resize.post()
            seen.append(terminal.wait(forOutput: "\u{1B}[6A\r\u{1B}[J"))
            terminal.resize(columns: 80, rows: 24)
            resize.post()
            seen.append(terminal.wait(forOutput: "\u{1B}[4A\r\u{1B}[J"))
            terminal.send("\u{1B}[B\r")
        }
        let index = try TerminalPrompt.run(cancelled: "", descriptor: terminal.secondary, resize: resize) { prompt in
            try prompt.choose("Pick one", rows: [MenuRow(["First"]), MenuRow([long])])
        }
        let drawn = terminal.finish()
        #expect(index == 1)
        #expect(seen.values == [true, true])
        let collapse = try #require(drawn.range(of: "\u{1B}[3A\r\u{1B}[J", options: .backwards))
        #expect(drawn[collapse.upperBound...].contains(long))
    }

    @Test("a resize redraws a tick menu, keeping what is ticked")
    func tickMenuRedrawsOnResize() throws {
        let terminal = try PseudoTerminal()
        let resize = try #require(ResizeNotifier())
        terminal.resize(columns: 80, rows: 24)
        let seen = Recorded()
        Thread.detachNewThread {
            guard terminal.wait(forOutput: "Two") else { return }
            terminal.resize(columns: 10, rows: 24)
            resize.post()
            seen.append(terminal.wait(forOutput: "\u{1B}[8A\r\u{1B}[J"))
            terminal.send("\r")
        }
        let ticked = try TerminalPrompt.run(cancelled: "", descriptor: terminal.secondary, resize: resize) { prompt in
            try prompt.chooseMany("Which?", rows: [MenuRow(["One"]), MenuRow(["Two"])], ticked: [0, 1])
        }
        _ = terminal.finish()
        #expect(ticked == [0, 1])
        #expect(seen.values == [true])
    }

    @Test("a resize to a shorter window shows fewer rows and counts the rest")
    func windowFollowsHeight() throws {
        let terminal = try PseudoTerminal()
        let resize = try #require(ResizeNotifier())
        terminal.resize(columns: 80, rows: 24)
        let seen = Recorded()
        Thread.detachNewThread {
            guard terminal.wait(forOutput: "4 more below") else { return }
            terminal.resize(columns: 80, rows: 12)
            resize.post()
            seen.append(terminal.wait(forOutput: "16 more below"))
            terminal.send("\r")
        }
        let index = try TerminalPrompt.run(cancelled: "", descriptor: terminal.secondary, resize: resize) { prompt in
            try prompt.choose("Pick one", rows: (1...20).map { MenuRow(["Row \($0)"]) })
        }
        _ = terminal.finish()
        #expect(index == 0)
        #expect(seen.values == [true])
    }

    @Test("a resize redraws a line being typed, keeping the answer")
    func lineRedrawsOnResize() throws {
        let terminal = try PseudoTerminal()
        let resize = try #require(ResizeNotifier())
        terminal.resize(columns: 80, rows: 24)
        let typed = String(repeating: "abcde", count: 6)
        let seen = Recorded()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            terminal.send(typed)
            guard terminal.wait(forOutput: typed) else { return }
            terminal.resize(columns: 10, rows: 24)
            resize.post()
            seen.append(terminal.wait(forOutput: "\u{1B}[3A\r\u{1B}[J"))
            terminal.send("\r")
        }
        let answer = try TerminalPrompt.run(cancelled: "", descriptor: terminal.secondary, resize: resize) { prompt in
            try prompt.ask("Name: ") { _ in nil }
        }
        _ = terminal.finish()
        #expect(answer == typed)
        #expect(seen.values == [true])
    }

    @Test("resizes redraw without stretching the idle wait, so a prompt no one answers still closes on time")
    func resizeKeepsDeadline() throws {
        let terminal = try PseudoTerminal()
        let resize = try #require(ResizeNotifier())
        let finished = Recorded()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            let stop = Date().addingTimeInterval(10)
            while finished.values.isEmpty, Date() < stop {
                resize.post()
                usleep(50_000)
            }
        }
        let started = Date()
        #expect(throws: PromptTimedOut.self) {
            try TerminalPrompt.run(cancelled: "", descriptor: terminal.secondary, idle: 0.5, resize: resize) { prompt in
                try prompt.choose("Pick one", options: ["One", "Two"])
            }
        }
        finished.append(true)
        _ = terminal.finish()
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("waiting for a key hooks SIGWINCH to the resize pipe with SA_RESTART, and puts the old action back after")
    func signalHook() throws {
        let notifier = try #require(ResizeNotifier.signal)
        let terminal = try PseudoTerminal()
        let before = Self.action(SIGWINCH)
        let during = Recorded()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            let hooked = Self.action(SIGWINCH)
            during.append(hooked.handler != before.handler)
            during.append(hooked.flags & SA_RESTART != 0)
            terminal.send("\r")
        }
        let index = try TerminalPrompt.run(cancelled: "", descriptor: terminal.secondary, resize: notifier) { prompt in
            try prompt.choose("Pick one", options: ["One"])
        }
        _ = terminal.finish()
        let after = Self.action(SIGWINCH)
        #expect(index == 0)
        #expect(during.values == [true, true])
        #expect(after.handler == before.handler)
        #expect(after.flags == before.flags)
    }

    @Test("a prompt with no resize source never hooks SIGWINCH")
    func noSourceNoHook() throws {
        let terminal = try PseudoTerminal()
        let before = Self.action(SIGWINCH)
        let during = Recorded()
        Thread.detachNewThread {
            guard terminal.wait(until: { $0.c_lflag & tcflag_t(ECHO) == 0 }) else { return }
            during.append(Self.action(SIGWINCH).handler == before.handler)
            terminal.send("\r")
        }
        _ = try TerminalPrompt.run(cancelled: "", descriptor: terminal.secondary) { try $0.choose("Pick one", options: ["One"]) }
        _ = terminal.finish()
        #expect(during.values == [true])
    }

    @Test("the notifier's pipe is close-on-exec and non-blocking, and a drain empties it")
    func notifierPipe() throws {
        let notifier = try #require(ResizeNotifier())
        for end in [notifier.readEnd, notifier.writeEnd] {
            #expect(fcntl(end, F_GETFD) & FD_CLOEXEC != 0)
            #expect(fcntl(end, F_GETFL) & O_NONBLOCK != 0)
        }
        #expect(!notifier.drain())
        for _ in 0..<100 { notifier.post() }
        #expect(notifier.drain())
        #expect(!notifier.drain())
    }

    @Test("the prompt's spinner measures the terminal every frame: after a narrowing it climbs the rows its last frame fills")
    func spinnerFollowsResize() async throws {
        let terminal = try PseudoTerminal()
        terminal.resize(columns: 60, rows: 24)
        let label = String(repeating: "Looking ", count: 6)
        let style = TerminalStyle.detect(isTerminal: true)
        try await TerminalSpinner.run(label, terminal: terminal.secondary) {
            try await Self.until { terminal.drawn.contains(label) }
            terminal.resize(columns: 20, rows: 24)
            try await Self.until { terminal.drawn.contains("\u{1B}[2A\r\u{1B}[J") }
        }
        let drawn = terminal.finish()
        #expect(drawn.contains("\u{1B}[2A\r\u{1B}[J"))
        #expect(drawn.contains(style.dim(TerminalText.truncate(label, to: 16, ellipsis: style.ellipsis))))
        #expect(drawn.hasSuffix("\r\u{1B}[J\u{1B}[?25h"))
    }

    static func until(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(PseudoTerminal.patience)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    static func action(_ number: Int32) -> (handler: UInt, flags: Int32) {
        var current = sigaction()
        sigaction(number, nil, &current)
        return (unsafeBitCast(current.__sigaction_u, to: UInt.self), current.sa_flags)
    }
}

/// Values a sender thread records for the test to check.
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []

    func append(_ value: Bool) {
        lock.withLock { stored.append(value) }
    }

    var values: [Bool] { lock.withLock { stored } }
}
