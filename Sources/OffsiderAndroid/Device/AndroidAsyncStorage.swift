import Foundation
import OffsiderCore

/// The scripts and fetch plan behind the AsyncStorage key names `app prefs` lists. The device prints a database's header, its log's frame headers, the schema page and index pages, and nothing else: no table page, so no value, ever crosses adb.
enum AndroidAsyncStorage {
    struct Store: Equatable, Sendable {
        let database: String
        let table: String
    }

    /// Where a page's newest copy is: the database file, or a frame in its write-ahead log.
    struct Source: Equatable, Sendable {
        let log: Bool
        let offset: Int
    }

    /// What the device says about a database between reads; a difference means the app wrote to it.
    struct Stamp: Equatable, Sendable {
        let database: String
        let header: [UInt8]
        let logBytes: Int
        let logHeader: [UInt8]
        let journal: [UInt8]
    }

    /// The library's opt-in Room database first, as an app that has both has moved to it.
    static let stores = [Store(database: "AsyncStorage", table: "Storage"), Store(database: "RKStorage", table: "catalystLocalStorage")]
    static let storageMarker = "\(AndroidAppPackage.marker) storage "
    static let pageMarker = "\(AndroidAppPackage.marker) page "
    static let frameMarker = "\(AndroidAppPackage.marker) frame "
    static let endMarker = "\(AndroidAppPackage.marker) end"
    static let pagesPerCall = 64
    static let maximumFrames = 1_024
    /// A rollback journal that starts with this is a write the app has not finished.
    static let journalMagic: [UInt8] = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]

    // MARK: Scripts

    /// `x` prints bytes as hex; `s` prints a database's stamp: its 100-byte header, its log's size and 32-byte header, and the first 8 bytes of its journal.
    static let functions = """
    x() { od -An -v -tx1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -dc 0-9a-f; }
    s() {
      [ -f "$1" ] || return 0
      w=0; [ -f "$1-wal" ] && w=$(wc -c <"$1-wal" 2>/dev/null | tr -dc 0-9)
      echo "\(storageMarker)$1 h=$(x "$1" 0 100) w=${w:-0} l=$(x "$1-wal" 0 32) j=$(x "$1-journal" 0 8)"
    }
    """

    /// Runs after the preference listing, in the same call, so an app with no database costs no extra round trip.
    static let probe = """
    \(functions)
    if cd databases 2>/dev/null; then \(stores.map { "s \($0.database)" }.joined(separator: "; ")); fi
    """

    /// One line per frame header of the log; the pages between them stay on the device.
    static func framesScript(package: String, store: Store, pageSize: Int, count: Int) -> String {
        let step = SQLiteKeyIndex.WriteAheadLog.frameHeaderBytes + pageSize
        return wrapped(package: package, store: store, """
        i=0
        while [ "$i" -lt \(count) ]; do
          echo "\(frameMarker)$(x \(store.database)-wal $((\(SQLiteKeyIndex.WriteAheadLog.headerBytes)+i*\(step))) \(SQLiteKeyIndex.WriteAheadLog.frameHeaderBytes))"
          i=$((i+1))
        done
        """)
    }

    /// The device reads each page once and prints it only if it is the schema leaf (`schema`) or an index page, so a table page cannot leave even if the app rewrote the file since the last call. It prints the page's header, cell pointers and cells, never the free space between them, which can hold bytes a table page left behind, nor the reserved bytes after them.
    static func pagesScript(package: String, store: Store, pageSize: Int, usable: Int, schema: Bool, sources: [Source]) -> String {
        let base = schema ? SQLiteKeyIndex.headerBytes : 0
        let requests = sources.map { "p \(store.database)\($0.log ? "-wal" : "") \($0.offset)" }.joined(separator: "\n")
        return wrapped(package: package, store: store, """
        p() {
          h=$(x "$1" "$2" \(pageSize))
          [ ${#h} -eq \(pageSize * 2) ] || { echo '\(pageMarker)short'; return 0; }
          case "${h:\(base * 2):2}" in \(schema ? "0d) k=8 ;;" : "0a) k=8 ;; 02) k=12 ;;") *) echo '\(pageMarker)refused'; return 0 ;; esac
          n=$((0x${h:\(base * 2 + 6):4})); c=$((0x${h:\(base * 2 + 10):4})); [ "$c" -ne 0 ] || c=65536
          e=$((\(base)+k+2*n))
          [ "$e" -le "$c" ] && [ "$c" -le \(usable) ] || { echo '\(pageMarker)refused'; return 0; }
          echo "\(pageMarker)${h:0:$((e*2))}:$c:${h:$((c*2)):$(((\(usable)-c)*2))}"
        }
        \(requests)
        """)
    }

    /// Each call ends with the database's stamp, taken after its reads, so a write during them shows.
    private static func wrapped(package: String, store: Store, _ body: String) -> String {
        let script = """
        cd databases 2>/dev/null || exit 0
        \(functions)
        \(body)
        s \(store.database)
        echo '\(endMarker)'
        """
        return "run-as \(ExpoDevClient.shellQuote(package)) sh -c \(ExpoDevClient.shellQuote(script))"
    }

    // MARK: Replies

    static func stamps(_ lines: [Substring]) -> [Stamp] {
        lines.compactMap { line in
            guard line.hasPrefix(storageMarker) else { return nil }
            let fields = line.dropFirst(storageMarker.count).split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 5, stores.contains(where: { $0.database == fields[0] }), fields[1].hasPrefix("h="), fields[2].hasPrefix("w="), fields[3].hasPrefix("l="), fields[4].hasPrefix("j="),
                  let header = bytes(hex: fields[1].dropFirst(2)), let logBytes = Int(fields[2].dropFirst(2)), let logHeader = bytes(hex: fields[3].dropFirst(2)), let journal = bytes(hex: fields[4].dropFirst(2)) else { return nil }
            return Stamp(database: String(fields[0]), header: header, logBytes: logBytes, logHeader: logHeader, journal: journal)
        }
    }

    static func stamps(_ stdout: String) -> [Stamp] {
        stamps(stdout.split(whereSeparator: \.isNewline))
    }

    /// A page as the device printed it, `<header and pointers>:<cell content offset>:<cells>`, with zeros for the free space between and the reserved bytes after. Nil for a refusal or anything out of shape.
    static func page(_ fields: Substring, pageSize: Int, usable: Int) -> [UInt8]? {
        let parts = fields.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let head = bytes(hex: parts[0]), let content = Int(parts[1]), let tail = bytes(hex: parts[2]), head.count <= content, content + tail.count == usable, usable <= pageSize else { return nil }
        return head + [UInt8](repeating: 0, count: content - head.count) + tail + [UInt8](repeating: 0, count: pageSize - usable)
    }

    static func bytes(hex: Substring) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    // MARK: Reading

    private enum Stop: Error {
        case changed(Stamp?)
        case unread(String)
    }

    /// The store's key names, read through `shell`, which runs one script and returns its stdout. A database that changes during the read is read once more; nothing here throws, so a failure never costs the caller its preference listing.
    @MainActor
    static func read(_ first: Stamp, store: Store, package: String, shell: (String) async throws -> String) async -> AppKeyStore {
        var stamp = first
        for _ in 0..<2 {
            do {
                return listed(try await keys(stamp, store: store, package: package, shell: shell), in: store)
            } catch Stop.changed(let latest?) {
                stamp = latest
            } catch Stop.unread(let word) {
                return AppKeyStore(database: store.database, keys: [], unread: word)
            } catch let failure as SQLiteKeyIndex.Failure {
                return AppKeyStore(database: store.database, keys: [], unread: failure.rawValue)
            } catch {
                return AppKeyStore(database: store.database, keys: [], unread: "failed")
            }
        }
        return AppKeyStore(database: store.database, keys: [], unread: "changing")
    }

    /// Masked and cut as a preference key is; a name its page held only the start of always ends in an ellipsis.
    static func listed(_ keys: [SQLiteKeyIndex.Key], in store: Store) -> AppKeyStore {
        let names = keys.map { key -> String in
            let shown = AndroidAppPackage.shown(key.name)
            return key.cut && !shown.hasSuffix("…") ? shown + "…" : shown
        }
        return AppKeyStore(database: store.database, keys: names.sorted(), cut: keys.filter(\.cut).count)
    }

    @MainActor
    private static func keys(_ stamp: Stamp, store: Store, package: String, shell: (String) async throws -> String) async throws -> [SQLiteKeyIndex.Key] {
        let header = try SQLiteKeyIndex.header(stamp.header)
        guard stamp.journal != journalMagic else { throw Stop.unread("unfinished") }

        func ask(_ script: String) async throws -> [Substring] {
            let lines = try await shell(script).split(whereSeparator: \.isNewline)
            guard lines.last == Substring(endMarker) else { throw Stop.unread("failed") }
            let latest = stamps(lines).first { $0.database == store.database }
            guard latest == stamp else { throw Stop.changed(latest) }
            return lines
        }

        var frames: [[UInt8]] = []
        if header.writeAheadLog {
            let count = SQLiteKeyIndex.WriteAheadLog.frameCount(logBytes: stamp.logBytes, pageSize: header.pageSize)
            guard count <= maximumFrames else { throw SQLiteKeyIndex.Failure.large }
            if count > 0 {
                let printed = try await ask(framesScript(package: package, store: store, pageSize: header.pageSize, count: count)).filter { $0.hasPrefix(frameMarker) }
                frames = printed.map { bytes(hex: $0.dropFirst(frameMarker.count)) ?? [] }
                guard frames.count == count else { throw Stop.unread("failed") }
            }
        }
        let log = SQLiteKeyIndex.WriteAheadLog(header: stamp.logHeader, frameHeaders: frames, pageSize: header.pageSize)

        func fetch(_ numbers: [Int], schema: Bool) async throws -> [[UInt8]] {
            let sources = numbers.map { number in log.offset(of: number).map { Source(log: true, offset: $0) } ?? Source(log: false, offset: (number - 1) * header.pageSize) }
            let printed = try await ask(pagesScript(package: package, store: store, pageSize: header.pageSize, usable: header.usableSize, schema: schema, sources: sources)).filter { $0.hasPrefix(pageMarker) }
            let pages = printed.compactMap { page($0.dropFirst(pageMarker.count), pageSize: header.pageSize, usable: header.usableSize) }
            guard printed.count == numbers.count, pages.count == numbers.count else { throw schema ? SQLiteKeyIndex.Failure.schema : SQLiteKeyIndex.Failure.corrupt }
            return pages
        }

        let schema = try await fetch([1], schema: true)
        var walk = SQLiteKeyIndex.Walk(root: try SQLiteKeyIndex.keyIndexRoot(schemaPage: schema[0], header: header, table: store.table))
        while !walk.wanted.isEmpty {
            var pages: [[UInt8]] = []
            for start in stride(from: 0, to: walk.wanted.count, by: pagesPerCall) {
                pages += try await fetch(Array(walk.wanted[start..<min(start + pagesPerCall, walk.wanted.count)]), schema: false)
            }
            try walk.take(pages, header: header)
        }
        return walk.keys
    }
}
