import Darwin
import Dispatch

/// Coarse widths: under 60 rows stack, 60 to 99 is the 80-column reference, wider adds detail; tables fit by exact width.
public enum Breakpoint: Int, Sendable, Comparable, CaseIterable {
    case narrow, regular, wide, veryWide

    public init(columns: Int) {
        switch columns {
        case ..<60: self = .narrow
        case ..<100: self = .regular
        case ..<160: self = .wide
        default: self = .veryWide
        }
    }

    public static func < (lhs: Breakpoint, rhs: Breakpoint) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a person's output is drawn: the terminal's true width and the stream's style.
public struct Canvas: Sendable, Equatable {
    public var columns: Int
    public var style: TerminalStyle

    public init(columns: Int, style: TerminalStyle) {
        self.columns = columns
        self.style = style
    }

    /// One short of the edge, so a glyph a terminal draws wider than counted never wraps the line.
    public var usable: Int { max(columns - 1, 1) }
    /// The widest prose runs: the usable width, at most 72 and never under 20.
    public var prose: Int { PromptScreen.width(columns: usable) }
    public var breakpoint: Breakpoint { Breakpoint(columns: columns) }
}

public enum TerminalSize {
    public static func columns(of descriptor: Int32) -> Int? {
        measure(descriptor).map { Int($0.ws_col) }
    }

    public static func rows(of descriptor: Int32) -> Int? {
        measure(descriptor).map { Int($0.ws_row) }
    }

    /// `COLUMNS` from 1 to 1000 wins, as a person sets it to test a width; else the measured width, else 80.
    public static func resolve(environment: [String: String], measured: Int?) -> Int {
        if let set = environment["COLUMNS"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), (1...1000).contains(set) { return set }
        if let measured, measured > 0 { return measured }
        return 80
    }

    private static func measure(_ descriptor: Int32) -> winsize? {
        var size = winsize()
        guard unsafe ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return size
    }
}

/// Calls `handler` on `queue` each time the terminal is resized, until `cancel`.
public final class TerminalResize: @unchecked Sendable {
    private let source: DispatchSourceSignal

    public init(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
    }

    public func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
