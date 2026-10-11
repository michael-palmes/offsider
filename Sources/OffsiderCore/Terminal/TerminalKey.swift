import Darwin

/// One key from a terminal in raw mode.
public enum TerminalKey: Equatable, Sendable {
    /// Typed bytes, possibly several characters pasted at once. A stray control character stays, so the answer is refused rather than saved without it.
    case text([UInt8])
    case enter
    case backspace
    case clearLine
    /// Control-W.
    case deleteWord
    case up
    case down
    case left
    case right
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
            case 0x17:
                flush(here); keys.append(.deleteWord)
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
                keys.append(arrows[final] ?? .ignored)
            default:
                if runStart == nil { runStart = here }
            }
        }
        flush(bytes.endIndex)
        return keys
    }

    /// The final byte of a CSI or SS3 arrow, whatever modifiers come before it.
    private static let arrows: [UInt8: TerminalKey] = [
        UInt8(ascii: "A"): .up, UInt8(ascii: "B"): .down, UInt8(ascii: "C"): .right, UInt8(ascii: "D"): .left,
    ]

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
    /// Masked input ignores Left and Right, and its Control-W deletes everything before the cursor, so the dots never show a word break.
    public let masked: Bool
    private let storage: SecretBytes
    /// Byte offset of the cursor, always at the start of a character or the end.
    public private(set) var cursor = 0

    public init(capacity: Int = LineEditor.defaultCapacity, masked: Bool = false) {
        storage = SecretBytes(capacity: capacity)
        self.masked = masked
    }

    public var capacity: Int { storage.capacity }
    public var isEmpty: Bool { storage.isEmpty }

    /// Characters typed so far, counting each Unicode scalar once.
    public var length: Int { storage.withBytes { $0.reduce(0) { $0 + ($1 & 0xC0 == 0x80 ? 0 : 1) } } }

    /// Swift cannot wipe a `String`, so a secret becomes one only here, once, at the hand-off.
    public var text: String { storage.withBytes { String(decoding: $0, as: UTF8.self) } }

    /// The text before the cursor, to place it. Never read for a masked answer.
    public var textBeforeCursor: String {
        storage.withBytes { String(decoding: UnsafeBufferPointer(rebasing: $0[..<cursor]), as: UTF8.self) }
    }

    /// True when `text` is exactly the bytes typed, compared without copying them.
    public func matches(_ text: String) -> Bool {
        storage.withBytes { text.utf8.elementsEqual($0) }
    }

    public func apply(_ key: TerminalKey) -> Outcome {
        switch key {
        case .text(let typed):
            cursor += storage.insert(typed, at: cursor)
        case .backspace:
            delete(from: characterStart(before: cursor))
        case .deleteWord:
            delete(from: masked ? 0 : wordStart(before: cursor))
        case .left where !masked:
            cursor = characterStart(before: cursor)
        case .right where !masked:
            cursor = characterEnd(after: cursor)
        case .clearLine:
            wipe()
        case .enter:
            return .submitted
        case .cancel:
            return .cancelled
        case .endOfInput:
            return isEmpty ? .cancelled : .editing
        case .up, .down, .left, .right, .ignored:
            break
        }
        return .editing
    }

    public func wipe() {
        storage.removeAll()
        cursor = 0
    }

    private func delete(from start: Int) {
        storage.remove(start..<cursor)
        cursor = start
    }

    private func characterEnd(after start: Int) -> Int {
        storage.withBytes { bytes in
            guard start < bytes.count else { return start }
            var index = start + 1
            while index < bytes.count, bytes[index] & 0xC0 == 0x80 { index += 1 }
            return index
        }
    }

    /// Where Control-W stops: back over spaces, then back over the word before them.
    private func wordStart(before end: Int) -> Int {
        storage.withBytes { bytes in
            let space: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 }
            var index = end
            while index > 0, space(bytes[index - 1]) { index -= 1 }
            while index > 0, !space(bytes[index - 1]) { index -= 1 }
            return index
        }
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
        case .backspace, .clearLine, .deleteWord, .left, .right, .ignored:
            break
        }
        return .moving
    }
}
