import Darwin
import Foundation

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
    /// Control-C or Control-backslash.
    case cancel
    /// Escape on its own: a cancel everywhere but a menu's filter, which it clears first.
    case escape
    /// Control-D, or the terminal closing.
    case endOfInput
    case ignored
    /// The terminal changed size; never parsed from bytes, so a prompt redraws.
    case resize

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
                    keys.append(.escape)
                    continue
                }
                let introducer = bytes[index]
                if introducer == 0x1B {
                    keys.append(.escape)
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
        case .cancel, .escape:
            return .cancelled
        case .endOfInput:
            return isEmpty ? .cancelled : .editing
        case .up, .down, .left, .right, .ignored, .resize:
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

/// An arrow-key list: Up and Down wrap past disabled rows, Enter or a digit chooses, Escape or q cancels.
/// A long list given `search` text also filters: `/` starts it, every key after it is query text until Escape,
/// and Enter still returns the row's index in the full list.
public struct ChoiceMenu: Sendable {
    public enum Outcome: Equatable, Sendable {
        case moving
        case chosen(Int)
        case cancelled
        /// R in a menu that offers a rescan.
        case refresh
    }

    public let count: Int
    /// The row under the cursor; nil when no row can be chosen.
    public private(set) var selected: Int?
    public let refreshable: Bool
    /// Rows the screen shows at once; a list longer than this offers `/` however short it is.
    public var window: Int?
    /// What was typed after `/`; nil while the menu is not filtering.
    public private(set) var query: String?
    private let enabled: [Bool]
    /// Each row's text folded for matching; nil for a menu that never filters.
    private let search: [String]?
    /// The row under the cursor when filtering began.
    private var resume: Int?

    /// Past nine rows a digit no longer reaches every row, so `/` is offered.
    public static let filterAfter = 9
    /// The most characters a query keeps.
    public static let queryLimit = 64

    /// `disabled` rows are drawn but the cursor never lands on them; `selected` falls forward to the next enabled row.
    /// `search` is each row's text to filter on, such as its columns joined.
    public init(count: Int, selected: Int = 0, disabled: Set<Int> = [], refreshable: Bool = false, search: [String]? = nil) {
        self.count = max(count, 0)
        enabled = (0..<self.count).map { !disabled.contains($0) }
        self.refreshable = refreshable
        self.search = search.map { texts in (0..<max(count, 0)).map { $0 < texts.count ? MenuFilter.fold(texts[$0]) : "" } }
        self.selected = firstEnabled(from: selected)
    }

    /// True when `/` starts a filter: the menu has search text, a row to choose, and more rows than nine or the window.
    public var offersFilter: Bool {
        search != nil && enabled.contains(true) && (count > Self.filterAfter || window.map { count > $0 } ?? false)
    }

    /// The rows in view, in order: every row, or the ones the query matches. A disabled row that matches stays.
    public var shown: [Int] {
        guard let query, let search else { return Array(0..<count) }
        let terms = MenuFilter.terms(query)
        return (0..<count).filter { MenuFilter.matches(terms, search[$0]) }
    }

    public mutating func apply(_ key: TerminalKey) -> Outcome {
        if query != nil { return filter(key) }
        switch key {
        case .up:
            step(-1)
        case .down:
            step(1)
        case .enter:
            if let selected { return .chosen(selected) }
        case .cancel, .escape, .endOfInput:
            return .cancelled
        case .text(let typed):
            for (offset, byte) in typed.enumerated() {
                switch byte {
                case UInt8(ascii: "/") where offersFilter:
                    resume = selected
                    query = ""
                    type(typed[(offset + 1)...])
                    return .moving
                case UInt8(ascii: "k"): step(-1)
                case UInt8(ascii: "j"): step(1)
                case UInt8(ascii: "q"), UInt8(ascii: "Q"): return .cancelled
                case UInt8(ascii: "r") where refreshable, UInt8(ascii: "R") where refreshable: return .refresh
                case UInt8(ascii: "1")...UInt8(ascii: "9") where Int(byte - UInt8(ascii: "0")) <= count && enabled[Int(byte - UInt8(ascii: "1"))]:
                    selected = Int(byte - UInt8(ascii: "1"))
                    return .chosen(Int(byte - UInt8(ascii: "1")))
                default: break
                }
            }
        case .backspace, .clearLine, .deleteWord, .left, .right, .ignored, .resize:
            break
        }
        return .moving
    }

    /// A key while filtering: printable bytes are query text, arrows move among matches, the first Escape clears.
    private mutating func filter(_ key: TerminalKey) -> Outcome {
        switch key {
        case .up:
            step(-1)
        case .down:
            step(1)
        case .enter:
            if let selected { return .chosen(selected) }
        case .cancel, .endOfInput:
            return .cancelled
        case .escape:
            leaveFilter()
        case .backspace:
            guard let query, !query.isEmpty else {
                leaveFilter()
                break
            }
            self.query = String(query.dropLast())
            refilter()
        case .clearLine:
            query = ""
            refilter()
        case .deleteWord:
            query = String((query ?? "").reversed().drop { $0 == " " }.drop { $0 != " " }.reversed())
            refilter()
        case .text(let typed):
            type(typed[...])
        case .left, .right, .ignored, .resize:
            break
        }
        return .moving
    }

    private mutating func type(_ bytes: ArraySlice<UInt8>) {
        let printable = bytes.filter { $0 >= 0x20 && $0 != 0x7F }
        guard var text = query, !printable.isEmpty else { return }
        for character in String(decoding: printable, as: UTF8.self) {
            guard text.count < Self.queryLimit else { break }
            text.append(character)
        }
        query = text
        refilter()
    }

    /// The cursor goes to the first match it can land on, or nowhere when none matches.
    private mutating func refilter() {
        selected = shown.first { enabled[$0] }
    }

    /// Every row shows again with the cursor where it was, or where it was before filtering when no row matched.
    private mutating func leaveFilter() {
        query = nil
        if selected == nil { selected = firstEnabled(from: resume ?? 0) }
    }

    private func firstEnabled(from selected: Int) -> Int? {
        let start = min(max(selected, 0), max(count - 1, 0))
        return (0..<count).map { (start + $0) % count }.first { enabled[$0] }
    }

    private mutating func step(_ by: Int) {
        let rows = shown.filter { enabled[$0] }
        guard let current = selected, let position = rows.firstIndex(of: current) else {
            selected = rows.first
            return
        }
        selected = rows[(position + by + rows.count) % rows.count]
    }
}

/// How a menu filter matches: case, accents and full-width forms folded away, and every space-separated term somewhere in the row.
private enum MenuFilter {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func terms(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `folded` is a row's text already folded.
    static func matches(_ terms: [String], _ folded: String) -> Bool {
        terms.allSatisfy { folded.contains($0) }
    }
}

/// A menu where Space ticks rows and Enter takes every ticked one; Enter with none ticked does nothing.
public struct CheckMenu: Sendable {
    public enum Outcome: Equatable, Sendable {
        case moving
        case chosen([Int])
        case cancelled
    }

    public let count: Int
    public private(set) var selected: Int
    public private(set) var ticked: Set<Int>

    public init(count: Int, ticked: Set<Int>) {
        self.count = max(count, 0)
        selected = 0
        self.ticked = ticked.filter { (0..<max(count, 0)).contains($0) }
    }

    public mutating func apply(_ key: TerminalKey) -> Outcome {
        guard count > 0 else { return [.cancel, .escape, .endOfInput].contains(key) ? .cancelled : .moving }
        switch key {
        case .up: selected = (selected - 1 + count) % count
        case .down: selected = (selected + 1) % count
        case .enter: if !ticked.isEmpty { return .chosen(ticked.sorted()) }
        case .cancel, .escape, .endOfInput: return .cancelled
        case .text(let typed):
            for byte in typed {
                switch byte {
                case UInt8(ascii: " "): toggle(selected)
                case UInt8(ascii: "k"): selected = (selected - 1 + count) % count
                case UInt8(ascii: "j"): selected = (selected + 1) % count
                case UInt8(ascii: "q"), UInt8(ascii: "Q"): return .cancelled
                case UInt8(ascii: "1")...UInt8(ascii: "9") where Int(byte - UInt8(ascii: "0")) <= count:
                    selected = Int(byte - UInt8(ascii: "1"))
                    toggle(selected)
                default: break
                }
            }
        case .backspace, .clearLine, .deleteWord, .left, .right, .ignored, .resize:
            break
        }
        return .moving
    }

    private mutating func toggle(_ index: Int) {
        if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) }
    }
}
