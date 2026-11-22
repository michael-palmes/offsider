import Foundation

/// Reads key names out of a SQLite table's automatic index, from pages another program wrote. It takes the database header, the schema page and index pages, never a table row, and never follows an overflow chain, so a value has no way in.
public enum SQLiteKeyIndex {
    /// One word for why a database was not read, as `app prefs` reports it.
    public enum Failure: String, Error, Equatable, Sendable, CaseIterable {
        case format, utf16, schema, corrupt, large
    }

    public struct Header: Equatable, Sendable {
        public var pageSize: Int
        /// Bytes at the end of every page kept for an extension, which hold no cell.
        public var reserved: Int
        public var writeAheadLog: Bool

        public init(pageSize: Int, reserved: Int = 0, writeAheadLog: Bool) {
            self.pageSize = pageSize
            self.reserved = reserved
            self.writeAheadLog = writeAheadLog
        }

        public var usableSize: Int { pageSize - reserved }
    }

    public struct Key: Equatable, Sendable {
        public var name: String
        /// The name runs past what its page holds in place, so only its first part is here.
        public var cut: Bool

        public init(name: String, cut: Bool = false) {
            self.name = name
            self.cut = cut
        }
    }

    public struct IndexPage: Equatable, Sendable {
        public var keys: [Key]
        public var children: [Int]
    }

    public static let headerBytes = 100
    static let minimumPageSize = 512
    static let minimumUsableSize = 480
    static let magic = Array("SQLite format 3".utf8) + [0]

    // MARK: Header

    public static func header(_ bytes: [UInt8]) throws -> Header {
        guard bytes.count >= headerBytes, Array(bytes[0..<16]) == magic else { throw Failure.format }
        let stored = Int(bytes[16]) << 8 | Int(bytes[17])
        let pageSize = stored == 1 ? 65_536 : stored
        guard pageSize >= minimumPageSize, pageSize <= 65_536, pageSize & (pageSize - 1) == 0 else { throw Failure.format }
        guard (1...2).contains(bytes[18]), (1...2).contains(bytes[19]), pageSize - Int(bytes[20]) >= minimumUsableSize, bytes[21] == 64, bytes[22] == 32, bytes[23] == 32 else { throw Failure.format }
        switch word(bytes, 56) {
        case 0, 1: break
        case 2, 3: throw Failure.utf16
        default: throw Failure.format
        }
        return Header(pageSize: pageSize, reserved: Int(bytes[20]), writeAheadLog: bytes[19] == 2)
    }

    // MARK: Schema

    /// The root page of `table`'s key index, from page 1. A schema that fills more than page 1 is not read, as its other pages look like any table's. Nor is one with any other index or a `WITHOUT ROWID` table, whose pages look like the key index's and can hold rows.
    public static func keyIndexRoot(schemaPage page: [UInt8], header: Header, table: String) throws -> Int {
        let usable = try usableSize(of: page, header: header, else: .schema)
        guard page[headerBytes] == 13 else { throw Failure.schema }
        var declared = false
        var root: Int?
        for cell in try cells(page, base: headerBytes, headerSize: 8, usable: usable) {
            guard let payload = varint(page, at: cell, limit: usable), let rowid = varint(page, at: cell + payload.length, limit: usable) else { throw Failure.corrupt }
            let start = cell + payload.length + rowid.length
            guard payload.value <= UInt64(usable - 35) else { throw Failure.schema }
            guard start + Int(payload.value) <= usable else { throw Failure.corrupt }
            let columns = try record(page, start: start, local: Int(payload.value), total: Int(payload.value))
            guard columns.count >= 5, case .text(let type) = columns[0], case .text(let name) = columns[1], case .text(let owner) = columns[2] else { throw Failure.schema }
            switch text(page, type) {
            case "table":
                guard case .text(let sql) = columns[4] else { throw Failure.schema }
                if text(page, name) == table {
                    declared = declaresKeyIndex(text(page, sql))
                } else if plainWords(text(page, sql)).contains("without rowid") {
                    throw Failure.schema
                }
            case "index":
                guard root == nil, text(page, name) == "sqlite_autoindex_\(table)_1", text(page, owner) == table, case .integer(let number) = columns[3], number >= 2, number <= Int64(Int32.max) else { throw Failure.schema }
                root = Int(number)
            default:
                break
            }
        }
        guard declared, let root else { throw Failure.schema }
        return root
    }

    /// Whether the table's only unique constraint is a primary key on `key`, so its first automatic index holds key names and nothing else.
    static func declaresKeyIndex(_ sql: String) -> Bool {
        let words = plainWords(sql)
        guard !words.contains("without rowid"), !words.contains("unique"), words.components(separatedBy: "primary key").count == 2 else { return false }
        return words.contains(#/[(,] ?key text( not null)? primary key/#) || words.contains(#/primary key ?\( ?key ?\)/#)
    }

    /// Lower case, quotes dropped, one space between words.
    private static func plainWords(_ sql: String) -> String {
        sql.lowercased().filter { !"`\"'[]".contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Index pages

    /// The key names on one index page and, for an interior page, its children. A cell that is not text is no name and is skipped.
    public static func indexPage(_ page: [UInt8], header: Header) throws -> IndexPage {
        let usable = try usableSize(of: page, header: header, else: .corrupt)
        guard page[0] == 2 || page[0] == 10 else { throw Failure.corrupt }
        let interior = page[0] == 2
        let maximumLocal = (usable - 12) * 64 / 255 - 23
        let minimumLocal = (usable - 12) * 32 / 255 - 23
        var result = IndexPage(keys: [], children: [])
        for cell in try cells(page, base: 0, headerSize: interior ? 12 : 8, usable: usable) {
            var offset = cell
            if interior {
                guard offset + 4 <= usable else { throw Failure.corrupt }
                result.children.append(Int(word(page, offset)))
                offset += 4
            }
            guard let payload = varint(page, at: offset, limit: usable), payload.value <= UInt64(Int32.max) else { throw Failure.corrupt }
            offset += payload.length
            let total = Int(payload.value)
            var local = total
            if total > maximumLocal {
                let surplus = minimumLocal + (total - minimumLocal) % (usable - 4)
                local = surplus <= maximumLocal ? surplus : minimumLocal
                guard offset + local + 4 <= usable else { throw Failure.corrupt }
            }
            guard offset + local <= usable else { throw Failure.corrupt }
            guard case .text(let range)? = try record(page, start: offset, local: local, total: total).first else { continue }
            let cut = range.declared > range.bytes.count
            result.keys.append(Key(name: cut ? wholeCharacters(page[range.bytes]) : text(page, range), cut: cut))
        }
        if interior { result.children.append(Int(word(page, 8))) }
        return result
    }

    /// The pages of one index, a level at a time: fetch `wanted`, hand them to `take`, and repeat until nothing is wanted.
    public struct Walk: Sendable {
        public static let maximumPages = 4_096

        public private(set) var wanted: [Int]
        public private(set) var keys: [Key] = []
        private var seen: Set<Int>

        public init(root: Int) {
            wanted = [root]
            seen = [root]
        }

        /// `pages` in the order of `wanted`. A page reached twice means a broken tree, and one past the limit a database too large to list.
        public mutating func take(_ pages: [[UInt8]], header: Header) throws {
            guard pages.count == wanted.count else { throw Failure.corrupt }
            var next: [Int] = []
            for page in pages {
                let parsed = try SQLiteKeyIndex.indexPage(page, header: header)
                keys += parsed.keys
                for child in parsed.children {
                    guard child >= 2, seen.insert(child).inserted else { throw Failure.corrupt }
                    guard seen.count <= Self.maximumPages else { throw Failure.large }
                    next.append(child)
                }
            }
            wanted = next
        }
    }

    // MARK: Write-ahead log

    /// Which pages a write-ahead log holds, from its header and frame headers alone. A frame is told from a stale one by its salts and commit markers, never by its checksum, which needs the page.
    public struct WriteAheadLog: Equatable, Sendable {
        public static let headerBytes = 32
        public static let frameHeaderBytes = 24

        public let pageSize: Int
        /// Each page the committed frames hold, with the index of its newest frame.
        public private(set) var frames: [Int: Int] = [:]

        public static func frameCount(logBytes: Int, pageSize: Int) -> Int {
            max(0, (logBytes - headerBytes) / (frameHeaderBytes + pageSize))
        }

        public static func frameOffset(_ index: Int, pageSize: Int) -> Int {
            headerBytes + index * (frameHeaderBytes + pageSize)
        }

        /// A header that does not check out leaves the log empty, as SQLite itself treats it.
        public init(header: [UInt8], frameHeaders: [[UInt8]], pageSize: Int) {
            self.pageSize = pageSize
            guard header.count == Self.headerBytes, word(header, 0) & ~1 == 0x377f_0682, word(header, 4) == 3_007_000, Int(word(header, 8)) == pageSize else { return }
            guard Self.checksum(header, bigEndian: word(header, 0) & 1 == 1) == (word(header, 24), word(header, 28)) else { return }
            var open: [Int: Int] = [:]
            for (index, frame) in frameHeaders.enumerated() {
                guard frame.count == Self.frameHeaderBytes, word(frame, 0) >= 1, word(frame, 8) == word(header, 16), word(frame, 12) == word(header, 20) else { break }
                open[Int(word(frame, 0))] = index
                if word(frame, 4) != 0 {
                    frames.merge(open) { _, newer in newer }
                    open.removeAll(keepingCapacity: true)
                }
            }
        }

        /// Where `page`'s bytes start in the log, or nil when the database file holds its newest copy.
        public func offset(of page: Int) -> Int? {
            frames[page].map { Self.frameOffset($0, pageSize: pageSize) + Self.frameHeaderBytes }
        }

        static func checksum(_ header: [UInt8], bigEndian: Bool) -> (UInt32, UInt32) {
            var first: UInt32 = 0
            var second: UInt32 = 0
            for offset in stride(from: 0, to: 24, by: 8) {
                let pair = (word(header, offset), word(header, offset + 4))
                first &+= (bigEndian ? pair.0 : pair.0.byteSwapped) &+ second
                second &+= (bigEndian ? pair.1 : pair.1.byteSwapped) &+ first
            }
            return (first, second)
        }
    }

    // MARK: Bytes

    private enum Column {
        case text(TextRange)
        case integer(Int64)
        case other
    }

    private struct TextRange {
        /// The bytes of the text that lie on this page.
        var bytes: Range<Int>
        /// The length the record declares, which is longer when the rest sits on overflow pages.
        var declared: Int
    }

    /// The part of a page that holds cells, once the page is the size its header says and that size is one SQLite allows.
    private static func usableSize(of page: [UInt8], header: Header, else failure: Failure) throws -> Int {
        guard page.count == header.pageSize, page.count >= minimumPageSize, header.reserved >= 0, header.usableSize >= minimumUsableSize else { throw failure }
        return header.usableSize
    }

    /// The cell offsets a b-tree page's pointer array lists, each checked to lie in the cell content area.
    private static func cells(_ page: [UInt8], base: Int, headerSize: Int, usable: Int) throws -> [Int] {
        let count = Int(page[base + 3]) << 8 | Int(page[base + 4])
        let stored = Int(page[base + 5]) << 8 | Int(page[base + 6])
        let content = stored == 0 ? 65_536 : stored
        let pointers = base + headerSize
        guard pointers + 2 * count <= content, content <= usable else { throw Failure.corrupt }
        return try (0..<count).map { index in
            let offset = Int(page[pointers + 2 * index]) << 8 | Int(page[pointers + 2 * index + 1])
            guard offset >= content, offset < usable else { throw Failure.corrupt }
            return offset
        }
    }

    /// A record's columns, from its header. Only `local` of its `total` bytes are on this page; text is clipped to them.
    private static func record(_ page: [UInt8], start: Int, local: Int, total: Int) throws -> [Column] {
        let end = start + local
        guard let size = varint(page, at: start, limit: end), size.value >= 1, size.value <= UInt64(local) else { throw Failure.corrupt }
        let headerEnd = start + Int(size.value)
        var offset = start + size.length
        var body = Int(size.value)
        var columns: [Column] = []
        while offset < headerEnd {
            guard let type = varint(page, at: offset, limit: headerEnd) else { throw Failure.corrupt }
            offset += type.length
            let length: Int
            switch type.value {
            case 0, 8, 9: length = 0
            case 1...4: length = Int(type.value)
            case 5: length = 6
            case 6, 7: length = 8
            case 10, 11: throw Failure.corrupt
            default:
                guard type.value <= UInt64(Int32.max) else { throw Failure.corrupt }
                length = (Int(type.value) - 12) / 2
            }
            guard body + length <= total else { throw Failure.corrupt }
            let from = min(start + body, end)
            let onPage = from..<min(start + body + length, end)
            switch type.value {
            case 1...6 where onPage.count == length: columns.append(.integer(integer(page, onPage)))
            case 8, 9: columns.append(.integer(Int64(type.value) - 8))
            case let value where value >= 13 && value % 2 == 1: columns.append(.text(TextRange(bytes: onPage, declared: length)))
            default: columns.append(.other)
            }
            body += length
        }
        return columns
    }

    /// A SQLite varint: at most nine bytes, the ninth whole. Nil when it runs past `limit`.
    private static func varint(_ bytes: [UInt8], at offset: Int, limit: Int? = nil) -> (value: UInt64, length: Int)? {
        let limit = min(limit ?? bytes.count, bytes.count)
        var value: UInt64 = 0
        for index in 0..<9 {
            guard offset >= 0, offset + index < limit else { return nil }
            let byte = bytes[offset + index]
            if index == 8 { return (value << 8 | UInt64(byte), 9) }
            value = value << 7 | UInt64(byte & 0x7f)
            if byte & 0x80 == 0 { return (value, index + 1) }
        }
        return nil
    }

    private static func integer(_ bytes: [UInt8], _ range: Range<Int>) -> Int64 {
        var value: Int64 = bytes[range.lowerBound] & 0x80 == 0 ? 0 : -1
        for index in range { value = value << 8 | Int64(bytes[index]) }
        return value
    }

    private static func text(_ page: [UInt8], _ range: TextRange) -> String {
        String(decoding: page[range.bytes], as: UTF8.self)
    }

    /// Text cut at a byte boundary, without the character the cut split.
    private static func wholeCharacters(_ bytes: ArraySlice<UInt8>) -> String {
        var bytes = bytes
        for back in 1...3 {
            guard bytes.count >= back else { break }
            let byte = bytes[bytes.endIndex - back]
            guard byte & 0xc0 != 0x80 else { continue }
            let needed = byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : byte >= 0xc0 ? 2 : 1
            if needed > back { bytes = bytes.dropLast(back) }
            break
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A big-endian 32-bit word; the caller has checked the four bytes are there.
private func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}
