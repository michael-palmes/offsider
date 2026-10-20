import Darwin
import Foundation

/// The one writer: the body on stdout, notices on stderr in each reader's words, and a person's spinner over pauses.
public final class Console: @unchecked Sendable {
    public enum Stream: Sendable {
        case out, err
    }

    /// Who reads one stream and how wide it is.
    public struct Channel: Sendable {
        public var profile: OutputProfile
        public var canvas: Canvas
        public var isTerminal: Bool
        /// A spinner may draw: a person's terminal that is not `TERM=dumb`.
        public var animates: Bool

        public init(profile: OutputProfile, canvas: Canvas, isTerminal: Bool, animates: Bool) {
            self.profile = profile
            self.canvas = canvas
            self.isTerminal = isTerminal
            self.animates = animates
        }

        public static let agent = Channel(profile: .agent, canvas: Canvas(columns: 80, style: .plain), isTerminal: false, animates: false)

        public static func person(columns: Int = 80, style: TerminalStyle = .plain, isTerminal: Bool = true) -> Channel {
            Channel(profile: .person, canvas: Canvas(columns: columns, style: style), isTerminal: isTerminal, animates: isTerminal)
        }
    }

    @TaskLocal public static var current: Console = .live
    public static let live = Console(fixed: nil, write: standardWrite)

    /// How long a pause runs before the spinner draws, and how often it turns.
    static let spinnerDelay = DispatchTimeInterval.milliseconds(200)
    static let spinnerFrame = DispatchTimeInterval.milliseconds(80)

    private let fixed: (out: Channel, err: Channel)?
    private let write: @Sendable (Stream, String) -> Void
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "offsider.console.spinner")
    private var seen: Set<Notice> = []
    private var counts: [Notice.Kind: Int] = [:]
    private var labels: [String] = []
    private var timer: DispatchSourceTimer?
    private var started = Date()
    /// Columns the spinner line covers now; 0 when nothing is drawn.
    private var drawn = 0

    public init(out: Channel, err: Channel, write: @escaping @Sendable (Stream, String) -> Void) {
        fixed = (out, err)
        self.write = write
    }

    private init(fixed: (out: Channel, err: Channel)?, write: @escaping @Sendable (Stream, String) -> Void) {
        self.fixed = fixed
        self.write = write
    }

    /// stdout's reader; the live console reads the profile on every call, so a test's profile override applies.
    public var out: Channel { fixed?.out ?? Self.channel(.out) }
    /// stderr's reader: a person only when `ErrorAudience` says so, and never under `--json`.
    public var err: Channel { fixed?.err ?? Self.channel(.err) }

    /// The body on stdout, then each notice not shown before on stderr.
    public func show(_ page: Page) {
        let out = self.out
        let body = out.profile == .person ? PersonRenderer.body(page.blocks, canvas: out.canvas) : AgentRenderer.body(page.blocks)
        if !body.isEmpty { emit(.out, body) }
        let fresh = lock.withLock { page.notices.filter { seen.insert($0).inserted } }
        guard !fresh.isEmpty else { return }
        let err = self.err
        if err.profile == .agent {
            emit(.err, AgentRenderer.notices(fresh))
            return
        }
        lock.withLock { for notice in fresh { counts[notice.kind, default: 0] += 1 } }
        emit(.err, PersonRenderer.notices(fresh, canvas: err.canvas, afterBody: !body.isEmpty && out.isTerminal && err.isTerminal))
    }

    /// Text as it is, such as JSON or a legacy line.
    public func data(_ text: String, to stream: Stream = .out) {
        guard !text.isEmpty else { return }
        emit(stream, text)
    }

    /// One notice on stderr, once per process; a person sees at most five of a kind.
    public func notice(_ notice: Notice) {
        guard lock.withLock({ seen.insert(notice).inserted }) else { return }
        let err = self.err
        guard err.profile == .person else {
            emit(.err, AgentRenderer.notice(notice))
            return
        }
        let shown = lock.withLock { () -> Int in
            defer { counts[notice.kind, default: 0] += 1 }
            return counts[notice.kind, default: 0]
        }
        if shown < PersonRenderer.noticesPerKind {
            emit(.err, PersonRenderer.notices([notice], canvas: err.canvas, afterBody: false))
        } else if shown == PersonRenderer.noticesPerKind, notice.kind != .next {
            emit(.err, "    " + err.canvas.style.dim("\(err.canvas.style.ellipsis)and more") + "\n")
        }
    }

    /// Runs `work` under a spinner on a person's terminal, drawn after 200 ms and erased when it ends; agents see nothing.
    public func progress<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let err = self.err
        guard err.animates, err.profile == .person else { return try await work() }
        begin(label)
        defer { end() }
        return try await work()
    }

    /// Changes what the running spinner says.
    public func relabel(_ label: String) {
        lock.withLock {
            guard !labels.isEmpty else { return }
            labels[labels.count - 1] = label
        }
    }

    private func emit(_ stream: Stream, _ text: String) {
        guard !text.isEmpty else { return }
        lock.withLock {
            clearSpinner()
            write(stream, text)
        }
    }

    /// Call with the lock held.
    private func clearSpinner() {
        guard drawn > 0 else { return }
        write(.err, "\r" + String(repeating: " ", count: drawn) + "\r")
        drawn = 0
    }

    private func begin(_ label: String) {
        lock.withLock {
            labels.append(label)
            guard timer == nil else { return }
            started = Date()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.spinnerDelay, repeating: Self.spinnerFrame)
            timer.setEventHandler { [weak self] in self?.frame() }
            self.timer = timer
            timer.resume()
        }
    }

    private func end() {
        lock.withLock {
            labels.removeLast()
            guard labels.isEmpty else { return }
            timer?.cancel()
            timer = nil
            clearSpinner()
        }
    }

    private func frame() {
        let canvas = err.canvas
        lock.withLock {
            guard timer != nil, let label = labels.last else { return }
            let style = canvas.style
            let frames = TerminalUI.spinnerFrames(style: style)
            let glyph = frames[Int(Date().timeIntervalSince(started) * 12.5) % frames.count]
            let shown = TerminalText.truncate(TerminalText.line(label, cap: nil, keepsTab: false), to: max(canvas.usable - 2, 1), ellipsis: style.ellipsis)
            let width = 2 + TerminalText.width(shown)
            let pad = String(repeating: " ", count: max(drawn - width, 0))
            write(.err, "\r" + style.cyan(glyph) + " " + style.dim(shown) + pad)
            drawn = max(width, drawn)
        }
    }

    private static func channel(_ stream: Stream) -> Channel {
        let descriptor = stream == .out ? STDOUT_FILENO : STDERR_FILENO
        let terminal = isatty(descriptor) != 0
        let profile: OutputProfile = stream == .out ? .current : (ErrorAudience.current == .person ? .person : .agent)
        return channel(
            stream, profile: profile, isTerminal: terminal, environment: ProcessInfo.processInfo.environment,
            measured: terminal ? TerminalSize.columns(of: descriptor) : nil
        )
    }

    /// Styling follows the stream: colour and a spinner only when a person reads a terminal; quoting follows `profile`.
    public static func channel(_ stream: Stream, profile: OutputProfile, isTerminal: Bool, environment: [String: String], measured: Int?) -> Channel {
        let person = profile == .person && isTerminal
        let columns = TerminalSize.resolve(environment: environment, measured: measured)
        return Channel(
            profile: profile, canvas: Canvas(columns: columns, style: .detect(isTerminal: person, environment: environment)), isTerminal: isTerminal,
            animates: stream == .err && person && environment["TERM"] != "dumb"
        )
    }

    /// stdout is flushed first, so these bytes stay in order with `print`; a closed pipe is ignored rather than raised.
    private static let standardWrite: @Sendable (Stream, String) -> Void = { stream, text in
        let data = Data(text.utf8)
        switch stream {
        case .out:
            unsafe fflush(stdout)
            try? FileHandle.standardOutput.write(contentsOf: data)
        case .err:
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }
}
