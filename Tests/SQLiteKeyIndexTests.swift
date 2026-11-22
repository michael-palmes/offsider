import Foundation
import Testing
@testable import OffsiderCore

/// A fixture database served a page at a time, noting each page asked for.
struct SQLiteFixture {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sqlite")
    /// In every value of every fixture, so it must never show in anything read from one.
    static let canary = "OFFSIDER-CANARY-VALUE-5e1d7c"
    static let all = ["legacy.db", "room.db", "two-level.db", "deep.db", "overflow.db", "empty.db", "utf16.db", "without-rowid.db", "value-first.db", "value-index.db", "rowless-neighbour.db", "reused.db", "wal.db", "wal-restarted.db"]

    let name: String
    let table: String
    var database: [UInt8]
    let log: [UInt8]

    init(_ name: String) throws {
        self.name = name
        table = name.hasPrefix("room") || name.hasPrefix("wal") ? "Storage" : "catalystLocalStorage"
        database = [UInt8](try Data(contentsOf: Self.folder.appendingPathComponent(name)))
        log = [UInt8]((try? Data(contentsOf: Self.folder.appendingPathComponent(name + "-wal"))) ?? Data())
    }

    /// The pages of the key index, as SQLite's own `dbstat` listed them when the fixture was made.
    var indexPages: Set<Int> {
        let listed = (try? String(contentsOf: Self.folder.appendingPathComponent(name + ".pages"), encoding: .utf8)) ?? ""
        return Set(listed.split(whereSeparator: \.isWhitespace).compactMap { Int($0) })
    }

    struct Reading {
        var keys: [SQLiteKeyIndex.Key] = []
        var asked: [Int] = []
    }

    func read() throws -> Reading {
        var reading = Reading()
        let header = try SQLiteKeyIndex.header(Array(database.prefix(SQLiteKeyIndex.headerBytes)))
        let size = header.pageSize
        let count = header.writeAheadLog ? SQLiteKeyIndex.WriteAheadLog.frameCount(logBytes: log.count, pageSize: size) : 0
        let frames = (0..<count).map { index -> [UInt8] in
            let offset = SQLiteKeyIndex.WriteAheadLog.frameOffset(index, pageSize: size)
            return Array(log[offset..<(offset + SQLiteKeyIndex.WriteAheadLog.frameHeaderBytes)])
        }
        let wal = SQLiteKeyIndex.WriteAheadLog(header: Array(log.prefix(SQLiteKeyIndex.WriteAheadLog.headerBytes)), frameHeaders: frames, pageSize: size)
        func page(_ number: Int) -> [UInt8] {
            reading.asked.append(number)
            if let offset = wal.offset(of: number) { return Array(log[offset..<(offset + size)]) }
            let start = (number - 1) * size
            return start + size <= database.count ? Array(database[start..<(start + size)]) : []
        }
        var walk = SQLiteKeyIndex.Walk(root: try SQLiteKeyIndex.keyIndexRoot(schemaPage: page(1), header: header, table: table))
        while !walk.wanted.isEmpty { try walk.take(walk.wanted.map(page), header: header) }
        reading.keys = walk.keys
        return reading
    }

    func names() throws -> [String] { try read().keys.map(\.name).sorted() }
}

@Suite("SQLite key index")
struct SQLiteKeyIndexTests {
    static func numbered(_ prefix: String, _ count: Int) -> [String] {
        (1...count).map { String(format: "\(prefix)-%04d", $0) }
    }

    @Test("each layout's key names come out whole, from one page or several levels of them")
    func names() throws {
        #expect(try SQLiteFixture("legacy.db").names() == ["", "offsider-fixture-profile", "offsider-fixture-theme", "session:person@example.com"])
        #expect(try SQLiteFixture("room.db").names() == ["offsider-fixture-profile", "offsider-fixture-theme", "third"])
        #expect(try SQLiteFixture("two-level.db").names() == Self.numbered("offsider-fixture-key", 300))
        #expect(try SQLiteFixture("deep.db").names() == Self.numbered("offsider-fixture-key", 1000))
        #expect(try SQLiteFixture("reused.db").names() == Self.numbered("offsider-fixture-key", 300))
        #expect(try SQLiteFixture("empty.db").names() == [])
    }

    @Test("a database with no reserved bytes at the end of its pages, as Android writes them, reads the same")
    func noReservedBytes() throws {
        for name in ["legacy.db", "two-level.db", "deep.db"] {
            var fixture = try SQLiteFixture(name)
            let expected = try fixture.names()
            #expect(fixture.database[20] == 12, "\(name): the Mac's sqlite3 reserves 12 bytes a page")
            fixture.database[20] = 0
            #expect(try fixture.names() == expected, "\(name)")
        }
    }

    @Test("a log's committed frames are read, and frames with no commit or from the log's last life are not")
    func writeAheadLog() throws {
        let cutOff = try SQLiteFixture("wal.db").names()
        #expect(cutOff == (["checkpointed", "offsider-fixture-profile", "offsider-fixture-theme"] + Self.numbered("committed", 60)).sorted())
        #expect(try SQLiteFixture("wal-restarted.db").names() == Self.numbered("kept", 80))
    }

    @Test("a log whose header fails its checksum is left out, as SQLite leaves it")
    func logHeaderChecksum() throws {
        let fixture = try SQLiteFixture("wal.db")
        var header = Array(fixture.log.prefix(32))
        let frames = [0, 1].map { index -> [UInt8] in
            let offset = SQLiteKeyIndex.WriteAheadLog.frameOffset(index, pageSize: 4096)
            return Array(fixture.log[offset..<(offset + 24)])
        }
        #expect(SQLiteKeyIndex.WriteAheadLog(header: header, frameHeaders: frames, pageSize: 4096).frames.count == 2)
        header[15] ^= 0x01
        #expect(SQLiteKeyIndex.WriteAheadLog(header: header, frameHeaders: frames, pageSize: 4096).frames.isEmpty)
    }

    @Test("a name too long for its page is cut, counted as cut, and its overflow pages are never asked for")
    func overflow() throws {
        let fixture = try SQLiteFixture("overflow.db")
        let reading = try fixture.read()
        #expect(reading.keys.filter(\.cut).count == 1)
        let long = try #require(reading.keys.first { $0.cut })
        #expect(long.name.hasPrefix("long-kkkk") && long.name.count < 1500)
        #expect(reading.keys.contains(SQLiteKeyIndex.Key(name: "short")))
        #expect(Set(reading.asked) == fixture.indexPages.union([1]))
    }

    @Test("only page 1 and the key index's own pages are ever asked for, each once")
    func pagesAsked() throws {
        for name in SQLiteFixture.all {
            let fixture = try SQLiteFixture(name)
            guard let reading = try? fixture.read() else { continue }
            #expect(Set(reading.asked) == fixture.indexPages.union([1]), "\(name)")
            #expect(reading.asked.count == Set(reading.asked).count, "\(name)")
        }
    }

    @Test("a database that is not AsyncStorage's shape is refused before any page but the schema's is asked for")
    func refusals() throws {
        #expect(throws: SQLiteKeyIndex.Failure.utf16) { try SQLiteFixture("utf16.db").read() }
        #expect(throws: SQLiteKeyIndex.Failure.schema) { try SQLiteFixture("without-rowid.db").read() }
        #expect(throws: SQLiteKeyIndex.Failure.schema) { try SQLiteFixture("value-first.db").read() }
        #expect(throws: SQLiteKeyIndex.Failure.schema) { try SQLiteFixture("value-index.db").read() }
        #expect(throws: SQLiteKeyIndex.Failure.schema) { try SQLiteFixture("rowless-neighbour.db").read() }
        let legacy = try SQLiteFixture("legacy.db")
        let header = try SQLiteKeyIndex.header(legacy.database)
        #expect(throws: SQLiteKeyIndex.Failure.schema) { try SQLiteKeyIndex.keyIndexRoot(schemaPage: Array(legacy.database.prefix(4096)), header: header, table: "Storage") }
        #expect(throws: SQLiteKeyIndex.Failure.format) { try SQLiteKeyIndex.header([UInt8](repeating: 0x5a, count: 100)) }
        #expect(throws: SQLiteKeyIndex.Failure.format) { try SQLiteKeyIndex.header(Array(legacy.database.prefix(99))) }
    }

    @Test("only a table whose one unique constraint is a primary key on key has its index read")
    func tableShapes() {
        #expect(SQLiteKeyIndex.declaresKeyIndex("CREATE TABLE catalystLocalStorage (key TEXT PRIMARY KEY, value TEXT NOT NULL)"))
        #expect(SQLiteKeyIndex.declaresKeyIndex("CREATE TABLE `Storage` (`key` TEXT NOT NULL, `value` TEXT, PRIMARY KEY(`key`))"))
        #expect(!SQLiteKeyIndex.declaresKeyIndex("CREATE TABLE catalystLocalStorage (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID"))
        #expect(!SQLiteKeyIndex.declaresKeyIndex("CREATE TABLE catalystLocalStorage (value TEXT UNIQUE, key TEXT PRIMARY KEY)"))
        #expect(!SQLiteKeyIndex.declaresKeyIndex("CREATE TABLE Storage (key TEXT, value TEXT, PRIMARY KEY(value))"))
        #expect(!SQLiteKeyIndex.declaresKeyIndex("CREATE TABLE Storage (key TEXT, value TEXT, PRIMARY KEY(key, value))"))
        #expect(!SQLiteKeyIndex.declaresKeyIndex("CREATE TABLE Storage (apikey TEXT PRIMARY KEY, value TEXT)"))
    }

    @Test("a table page handed over as an index page is refused, so its rows are never decoded")
    func tablePageRefused() throws {
        let legacy = try SQLiteFixture("legacy.db")
        let header = try SQLiteKeyIndex.header(legacy.database)
        let pages = stride(from: 0, to: legacy.database.count, by: 4096).map { Array(legacy.database[$0..<($0 + 4096)]) }
        let table = try #require(pages.first { $0[0] == 13 && Data($0).range(of: Data(SQLiteFixture.canary.utf8)) != nil })
        #expect(throws: SQLiteKeyIndex.Failure.corrupt) { try SQLiteKeyIndex.indexPage(table, header: header) }
    }

    @Test("a broken tree stops the walk: a page reached twice, a pointer outside the page, a tree past the page limit")
    func brokenTrees() throws {
        let fixture = try SQLiteFixture("two-level.db")
        let header = try SQLiteKeyIndex.header(fixture.database)
        let root = try SQLiteKeyIndex.keyIndexRoot(schemaPage: Array(fixture.database.prefix(4096)), header: header, table: fixture.table)
        var interior = Array(fixture.database[((root - 1) * 4096)..<(root * 4096)])
        #expect(interior[0] == 2)

        var looped = SQLiteKeyIndex.Walk(root: root)
        try looped.take([interior], header: header)
        #expect(throws: SQLiteKeyIndex.Failure.corrupt) { try looped.take(looped.wanted.map { _ in interior }, header: header) }

        var wrongCount = SQLiteKeyIndex.Walk(root: root)
        #expect(throws: SQLiteKeyIndex.Failure.corrupt) { try wrongCount.take([], header: header) }

        interior[12] = 0xff
        interior[13] = 0xff
        #expect(throws: SQLiteKeyIndex.Failure.corrupt) { try SQLiteKeyIndex.indexPage(interior, header: header) }
        #expect(throws: SQLiteKeyIndex.Failure.corrupt) { try SQLiteKeyIndex.indexPage(Array(interior.prefix(100)), header: header) }
    }

    @Test("a tree wider than the page limit is too large, not walked without end")
    func tooLarge() throws {
        let header = SQLiteKeyIndex.Header(pageSize: 512, writeAheadLog: false)
        let cells = 40
        func interior(firstChild: Int) -> [UInt8] {
            var page = [UInt8](repeating: 0, count: 512)
            page[0] = 2
            page[4] = UInt8(cells)
            var content = 512
            for index in 0..<cells {
                content -= 8
                let child = UInt32(firstChild + index)
                page.replaceSubrange(content..<(content + 8), with: [UInt8(child >> 24), UInt8(child >> 16 & 0xff), UInt8(child >> 8 & 0xff), UInt8(child & 0xff), 3, 2, 15, 0x61])
                page[12 + 2 * index] = UInt8(content >> 8)
                page[13 + 2 * index] = UInt8(content & 0xff)
            }
            page[5] = UInt8(content >> 8)
            page[6] = UInt8(content & 0xff)
            let last = UInt32(firstChild + cells)
            page.replaceSubrange(8..<12, with: [UInt8(last >> 24), UInt8(last >> 16 & 0xff), UInt8(last >> 8 & 0xff), UInt8(last & 0xff)])
            return page
        }
        var walk = SQLiteKeyIndex.Walk(root: 2)
        var next = 3
        let failure = #expect(throws: SQLiteKeyIndex.Failure.self) {
            while !walk.wanted.isEmpty {
                let pages = walk.wanted.map { _ -> [UInt8] in
                    defer { next += cells + 1 }
                    return interior(firstChild: next)
                }
                try walk.take(pages, header: header)
            }
        }
        #expect(failure == .large)
    }

    @Test("no fixture's canary value reaches a key name or a failure")
    func canary() throws {
        for name in SQLiteFixture.all {
            let fixture = try SQLiteFixture(name)
            #expect(Data(fixture.database + fixture.log).range(of: Data(SQLiteFixture.canary.utf8)) != nil || name == "utf16.db", "\(name) lost its canary")
            do {
                for key in try fixture.read().keys { #expect(!key.name.contains("CANARY"), "\(name)") }
            } catch {
                #expect(!"\(error)".contains("CANARY"), "\(name)")
            }
        }
    }

    @Test("every word the reader fails with is one app prefs reports, and each is in the docs")
    func unreadWords() throws {
        for failure in SQLiteKeyIndex.Failure.allCases {
            #expect(AppKeyStore.Unread(rawValue: failure.rawValue) != nil, "\(failure)")
        }
        let page = SQLiteFixture.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/device-state.md")
        let docs = try String(contentsOf: page, encoding: .utf8)
        for word in AppKeyStore.Unread.allCases {
            #expect(docs.contains("`\(word.rawValue)`"), "docs/device-state.md does not explain unread \(word.rawValue)")
        }
    }

    @Test("a 65536-byte page is read from the header's stand-in value of 1")
    func largestPage() throws {
        var header = Array(try SQLiteFixture("legacy.db").database.prefix(100))
        header[16] = 0
        header[17] = 1
        #expect(try SQLiteKeyIndex.header(header).pageSize == 65_536)
        header[17] = 3
        #expect(throws: SQLiteKeyIndex.Failure.format) { try SQLiteKeyIndex.header(header) }
    }
}
