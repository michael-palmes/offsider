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

    /// Splits one read into keys, copying each run of typed bytes once. An escape with nothing after it is the Escape key itself.
    public static func parse<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> [TerminalKey] {
        var keys: [TerminalKey] = []
        var runStart: Bytes.Index?
        func flush(_ end: Bytes.Index) {
            guard let start = runStart else { return }
            keys.append(.text(Array(bytes[start..<end])))
            runStart = nil
        }
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let here = index
            let byte = bytes[index]
            bytes.formIndex(after: &index)
            switch byte {
            case 0x0D, 0x0A:
                flush(here); keys.append(.enter)
            case 0x7F, 0x08:
                flush(here); keys.append(.backspace)
            case 0x15:
                flush(here); keys.append(.clearLine)
            case 0x03, 0x1C:
                flush(here); keys.append(.cancel)
            case 0x04:
                flush(here); keys.append(.endOfInput)
            case 0x1B:
                flush(here)
                guard index < bytes.endIndex else {
                    keys.append(.cancel)
                    continue
                }
                let introducer = bytes[index]
                if introducer == 0x1B {
                    keys.append(.cancel)
                    continue
                }
                bytes.formIndex(after: &index)
                guard introducer == UInt8(ascii: "[") || introducer == UInt8(ascii: "O") else {
                    keys.append(.ignored)
                    continue
                }
                if introducer == UInt8(ascii: "[") {
                    while index < bytes.endIndex, !(0x40...0x7E).contains(bytes[index]) { bytes.formIndex(after: &index) }
                }
                guard index < bytes.endIndex else {
                    keys.append(.ignored)
                    continue
                }
                let final = bytes[index]
                bytes.formIndex(after: &index)
                keys.append(final == UInt8(ascii: "A") ? .up : final == UInt8(ascii: "B") ? .down : .ignored)
            default:
                if runStart == nil { runStart = here }
            }
        }
        flush(bytes.endIndex)
        return keys
    }

    /// Zeroes the typed bytes this key holds, leaving it `.ignored`.
    public mutating func wipe() {
        guard case .text(var typed) = self else { return }
        self = .ignored
        typed.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    /// True when `bytes` stop inside an escape sequence, such as an arrow key split across two reads.
    public static func endsMidSequence(_ bytes: some BidirectionalCollection<UInt8>) -> Bool {
        guard let escape = bytes.lastIndex(of: 0x1B) else { return false }
        let tail = bytes[bytes.index(after: escape)...]
        switch tail.first {
        case nil: return true
        case UInt8(ascii: "["): return !tail.dropFirst().contains { (0x40...0x7E).contains($0) }
        case UInt8(ascii: "O"): return tail.count == 1
        default: return false
        }
    }
}

/// A one-line answer typed in raw mode, held in `SecretBytes` so its bytes are zeroed once read.
public final class LineEditor {
    public enum Outcome: Equatable, Sendable {
        case editing
        case submitted
        case cancelled
    }

    /// Bytes kept at most, so a stuck key cannot grow the answer without end.
    public static let defaultCapacity = 1024
    private let storage: SecretBytes

    public init(capacity: Int = LineEditor.defaultCapacity) {
        storage = SecretBytes(capacity: capacity)
    }

    public var capacity: Int { storage.capacity }
    public var isEmpty: Bool { storage.isEmpty }

    /// Characters typed so far, counting each Unicode scalar once.
    public var length: Int { storage.withBytes { $0.reduce(0) { $0 + ($1 & 0xC0 == 0x80 ? 0 : 1) } } }

    /// Swift cannot wipe a `String`, so a secret becomes one only here, once, at the hand-off.
    public var text: String { storage.withBytes { String(decoding: $0, as: UTF8.self) } }

    /// True when `text` is exactly the bytes typed, compared without copying them.
    public func matches(_ text: String) -> Bool {
        storage.withBytes { text.utf8.elementsEqual($0) }
    }

    public func apply(_ key: TerminalKey) -> Outcome {
        switch key {
        case .text(let typed):
            storage.insert(typed, at: storage.count)
        case .backspace:
            storage.remove(characterStart(before: storage.count)..<storage.count)
        case .clearLine:
            wipe()
        case .enter:
            return .submitted
        case .cancel:
            return .cancelled
        case .endOfInput:
            return isEmpty ? .cancelled : .editing
        case .up, .down, .ignored:
            break
        }
        return .editing
    }

    public func wipe() {
        storage.removeAll()
    }

    private func characterStart(before end: Int) -> Int {
        storage.withBytes { bytes in
            var index = end
            while index > 0 {
                index -= 1
                if bytes[index] & 0xC0 != 0x80 { break }
            }
            return index
        }
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
