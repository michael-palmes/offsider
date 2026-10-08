import Darwin

/// One key from a terminal in raw mode.
public enum TerminalKey: Equatable, Sendable {
    /// Typed bytes, possibly several characters pasted at once. A stray control character stays, so the answer is refused rather than saved without it.
    case text([UInt8])
    case enter
    case backspace
    case clearLine
    case up
    case down
    /// Escape, Control-C or Control-backslash.
    case cancel
    /// Control-D, or the terminal closing.
    case endOfInput
    case ignored

    /// Splits one read into keys. An escape with nothing after it is the Escape key itself.
    public static func parse(_ bytes: [UInt8]) -> [TerminalKey] {
        var keys: [TerminalKey] = []
        var run: [UInt8] = []
        func flush() {
            guard !run.isEmpty else { return }
            keys.append(.text(run))
            run.removeAll()
        }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x0D, 0x0A:
                flush(); keys.append(.enter)
            case 0x7F, 0x08:
                flush(); keys.append(.backspace)
            case 0x15:
                flush(); keys.append(.clearLine)
            case 0x03, 0x1C:
                flush(); keys.append(.cancel)
            case 0x04:
                flush(); keys.append(.endOfInput)
            case 0x1B:
                flush()
                guard index < bytes.count else {
                    keys.append(.cancel)
                    continue
                }
                let introducer = bytes[index]
                if introducer == 0x1B {
                    keys.append(.cancel)
                    continue
                }
                index += 1
                guard introducer == UInt8(ascii: "[") || introducer == UInt8(ascii: "O") else {
                    keys.append(.ignored)
                    continue
                }
                if introducer == UInt8(ascii: "[") {
                    while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) { index += 1 }
                }
                guard index < bytes.count else {
                    keys.append(.ignored)
                    continue
                }
                let final = bytes[index]
                index += 1
                keys.append(final == UInt8(ascii: "A") ? .up : final == UInt8(ascii: "B") ? .down : .ignored)
            default:
                run.append(byte)
            }
        }
        flush()
        return keys
    }
}

/// A one-line answer typed in raw mode. The bytes are wiped once read.
public struct LineEditor: Sendable {
    public enum Outcome: Equatable, Sendable {
        case editing
        case submitted
        case cancelled
    }

    public private(set) var bytes: [UInt8] = []
    /// Bytes kept at most, so a stuck key cannot grow the buffer without end.
    public let capacity: Int

    public init(capacity: Int = 1024) {
        self.capacity = capacity
    }

    /// Characters typed so far, counting each Unicode scalar once.
    public var length: Int { bytes.reduce(0) { $0 + ($1 & 0xC0 == 0x80 ? 0 : 1) } }

    public var text: String { String(decoding: bytes, as: UTF8.self) }

    public mutating func apply(_ key: TerminalKey) -> Outcome {
        switch key {
        case .text(let typed):
            bytes.append(contentsOf: typed.prefix(max(0, capacity - bytes.count)))
        case .backspace:
            while let last = bytes.popLast(), last & 0xC0 == 0x80 {}
        case .clearLine:
            wipe()
        case .enter:
            return .submitted
        case .cancel:
            return .cancelled
        case .endOfInput:
            return bytes.isEmpty ? .cancelled : .editing
        case .up, .down, .ignored:
            break
        }
        return .editing
    }

    public mutating func wipe() {
        bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        bytes.removeAll()
    }
}

/// An arrow-key list: Up and Down wrap, Enter or a digit chooses, Escape or q cancels.
public struct ChoiceMenu: Sendable {
    public enum Outcome: Equatable, Sendable {
        case moving
        case chosen(Int)
        case cancelled
    }

    public let count: Int
    public private(set) var selected = 0

    public init(count: Int) {
        self.count = max(count, 1)
    }

    public mutating func apply(_ key: TerminalKey) -> Outcome {
        switch key {
        case .up:
            selected = (selected + count - 1) % count
        case .down:
            selected = (selected + 1) % count
        case .enter:
            return .chosen(selected)
        case .cancel, .endOfInput:
            return .cancelled
        case .text(let typed):
            for byte in typed {
                switch byte {
                case UInt8(ascii: "k"): selected = (selected + count - 1) % count
                case UInt8(ascii: "j"): selected = (selected + 1) % count
                case UInt8(ascii: "q"), UInt8(ascii: "Q"): return .cancelled
                case UInt8(ascii: "1")...UInt8(ascii: "9") where Int(byte - UInt8(ascii: "0")) <= count:
                    selected = Int(byte - UInt8(ascii: "1"))
                    return .chosen(selected)
                default: break
                }
            }
        case .backspace, .clearLine, .ignored:
            break
        }
        return .moving
    }
}
