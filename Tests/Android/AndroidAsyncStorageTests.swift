import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// An app's data folder on a stand-in device: the scripts run under the Mac's `sh` with a `run-as` that enters the folder and an `od` that notes every read before making it.
final class AppDataDevice: @unchecked Sendable {
    struct Read: Equatable {
        let file: String
        let offset: Int
        let count: Int
    }

    let root: URL
    private let lock = NSLock()
    private var crossed = ""
    private var calls = 0
    /// Runs before each script after the first, so a test can change the files between two reads.
    var beforeCall: (@Sendable (Int) -> Void)?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-appdata-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/databases"), withIntermediateDirectories: true)
        try tool("run-as", "#!/bin/sh\nshift\ncd \"$OFFSIDER_APP_DATA\"\nexec \"$@\"\n")
        try tool("od", "#!/bin/sh\necho \"$*\" >> \"$OFFSIDER_APP_DATA/../reads\"\nexec /usr/bin/od \"$@\"\n")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func tool(_ name: String, _ body: String) throws {
        let url = root.appendingPathComponent("bin/\(name)")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var databases: URL { root.appendingPathComponent("data/databases") }

    /// Copies a fixture, and its log when it has one, in as the app's database `name`.
    func install(_ fixture: String, as name: String) throws {
        for suffix in ["", "-wal", "-journal"] { try? FileManager.default.removeItem(at: databases.appendingPathComponent(name + suffix)) }
        try FileManager.default.copyItem(at: SQLiteFixture.folder.appendingPathComponent(fixture), to: databases.appendingPathComponent(name))
        let log = SQLiteFixture.folder.appendingPathComponent(fixture + "-wal")
        if FileManager.default.fileExists(atPath: log.path) { try FileManager.default.copyItem(at: log, to: databases.appendingPathComponent(name + "-wal")) }
    }

    func writePreferences(_ name: String, _ text: String) throws {
        let folder = root.appendingPathComponent("data/shared_prefs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: folder.path + "/" + name, contents: Data(text.utf8)))
    }

    @discardableResult
    func run(_ script: String) -> (stdout: String, stderr: String) {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        if call > 1 { beforeCall?(call) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "\(root.path)/bin:/usr/bin:/bin", "OFFSIDER_APP_DATA": "\(root.path)/data"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        lock.withLock { crossed += stdout + stderr }
        return (stdout, stderr)
    }

    /// Everything the scripts printed, which is everything that would have crossed adb.
    var output: String { lock.withLock { crossed } }
    var scriptsRun: Int { lock.withLock { calls } }

    /// Every read the scripts made of the app's files, in order.
    var reads: [Read] {
        let log = (try? String(contentsOf: root.appendingPathComponent("reads"), encoding: .utf8)) ?? ""
        return log.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(separator: " ")
            guard let skip = words.firstIndex(of: "-j"), let length = words.firstIndex(of: "-N"), let file = words.last,
                  let offset = Int(words[skip + 1]), let count = Int(words[length + 1]) else { return nil }
            return Read(file: String(file), offset: offset, count: count)
        }
    }

    /// A backend whose adb shell is this device.
    @MainActor
    func backend() throws -> AndroidBackend {
        try AndroidAppLifecycleTests.setUp { [self] command in
            let result = run(command)
            return FakeAdbServer.shell(stdout: result.stdout, stderr: result.stderr)
        }.0
    }
}

@Suite("Android AsyncStorage key names")
@MainActor
struct AndroidAsyncStorageTests {
    static let package = "com.mpalmes.offsider.playground.rn"
    static let device = AndroidBackendTests.device
    static let legacy = AndroidAsyncStorage.stores[1]
    static let room = AndroidAsyncStorage.stores[0]

    /// The page layout every 4096-byte fixture has: the Mac's sqlite3 reserves 12 bytes a page.
    static let layout = (header: SQLiteKeyIndex.Header(pageSize: 4096, reserved: 12, writeAheadLog: false), bytes: [UInt8]([0x10, 0x00, 1, 1, 12]))

    static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }

    /// The database name a fixture is installed under, by the table it holds.
    static func store(for fixture: String) -> AndroidAsyncStorage.Store {
        fixture.hasPrefix("room") || fixture.hasPrefix("wal") ? room : legacy
    }

    static func read(_ fixture: String) async throws -> (keys: AppKeyStore?, device: AppDataDevice) {
        let device = try AppDataDevice()
        try device.install(fixture, as: store(for: fixture).database)
        return (try await device.backend().appPreferences(package, on: Self.device).asyncStorage, device)
    }

    @Test("every fixture's canary value stays on the device: not in a byte the scripts print, a key name or the report", arguments: SQLiteFixture.all)
    func canaryNeverCrosses(fixture: String) async throws {
        let (keys, device) = try await Self.read(fixture)
        let store = try #require(keys)
        for needle in ["CANARY", Self.hex("CANARY"), Self.hex("OFFSIDER-")] {
            #expect(!device.output.contains(needle), "\(fixture) printed \(needle)")
        }
        let report = AppManagementReport.preferences(AppPreferences(app: Self.package, files: [], asyncStorage: store), on: Self.device)
        #expect(!report.contains("CANARY") && !store.keys.contains { $0.contains("CANARY") }, "\(fixture)")
    }

    @Test("the device is asked for headers, the schema page and the key index's pages, and no other byte", arguments: SQLiteFixture.all)
    func onlyIndexPagesAreRead(fixture: String) async throws {
        let (_, device) = try await Self.read(fixture)
        let source = try SQLiteFixture(fixture)
        let name = Self.store(for: fixture).database
        let size = Int(source.database[16]) << 8 | Int(source.database[17])
        let allowed = source.indexPages.union([1])
        let frame = 24 + size
        #expect(!device.reads.isEmpty)
        for read in device.reads {
            switch (read.file, read.count) {
            case (name, 100): #expect(read.offset == 0)
            case (name, 5): #expect(read.offset == 16)
            case (name + "-wal", 32), (name + "-journal", 8): #expect(read.offset == 0)
            case (name + "-wal", 24): #expect(read.offset >= 32 && (read.offset - 32) % frame == 0, "\(read)")
            case (name, size):
                #expect(read.offset % size == 0 && allowed.contains(read.offset / size + 1), "\(fixture) read page \(read.offset / size + 1)")
            case (name + "-wal", size):
                let start = read.offset - 24
                #expect(start >= 32 && (start - 32) % frame == 0, "\(read)")
                let page = Int(source.log[start]) << 24 | Int(source.log[start + 1]) << 16 | Int(source.log[start + 2]) << 8 | Int(source.log[start + 3])
                #expect(allowed.contains(page), "\(fixture) read page \(page) from the log")
            default:
                Issue.record("\(fixture): an unexpected read, \(read)")
            }
        }
    }

    @Test("the names come back sorted, masked as preference keys are, through the device's own scripts")
    func names() async throws {
        let legacy = try #require(try await Self.read("legacy.db").keys)
        #expect(legacy == AppKeyStore(database: "RKStorage", keys: ["", "offsider-fixture-profile", "offsider-fixture-theme", "session:[redacted email]"]))
        #expect(try await Self.read("room.db").keys == AppKeyStore(database: "AsyncStorage", keys: ["offsider-fixture-profile", "offsider-fixture-theme", "third"]))
        let deep = try SQLiteFixture("deep.db")
        #expect(deep.indexPages.filter { deep.database[($0 - 1) * 512] == 10 }.count > AndroidAsyncStorage.pagesPerCall, "deep.db should need more than one call for its leaves")
        #expect(try await Self.read("deep.db").keys?.keys == SQLiteKeyIndexTests.numbered("offsider-fixture-key", 1000))
        #expect(try await Self.read("two-level.db").keys?.keys == SQLiteKeyIndexTests.numbered("offsider-fixture-key", 300))
        #expect(try await Self.read("empty.db").keys == AppKeyStore(database: "RKStorage", keys: []))
        let log = try #require(try await Self.read("wal.db").keys)
        #expect(log.keys.count == 63 && log.keys.contains("committed-0060") && !log.keys.contains { $0.hasPrefix("uncommitted") })
        #expect(try await Self.read("wal-restarted.db").keys?.keys == SQLiteKeyIndexTests.numbered("kept", 80))
    }

    @Test("a name its page holds only the start of is listed cut, counted, and ends in an ellipsis")
    func overflow() async throws {
        let store = try #require(try await Self.read("overflow.db").keys)
        #expect(store.cut == 1 && store.unread == nil)
        let long = try #require(store.keys.first { $0.hasPrefix("long-") })
        #expect(long.hasSuffix("…") && long.count <= AndroidAppPackage.maximumKeyCharacters + 1)
        #expect(store.keys.contains("short"))
    }

    @Test("a database that is not AsyncStorage's shape is named unread with one word, and nothing past its schema page is read")
    func unread() async throws {
        let shapes: [(String, AppKeyStore.Unread)] = [("utf16.db", .utf16), ("without-rowid.db", .schema), ("value-first.db", .schema), ("value-index.db", .schema), ("rowless-neighbour.db", .schema)]
        for (fixture, word) in shapes {
            let (keys, device) = try await Self.read(fixture)
            #expect(keys == AppKeyStore(database: "RKStorage", keys: [], unread: word), "\(fixture)")
            #expect(!device.reads.contains { $0.count >= 512 && $0.offset != 0 }, "\(fixture)")
        }
        let device = try AppDataDevice()
        try Data(repeating: 0x5a, count: 8192).write(to: device.databases.appendingPathComponent("RKStorage"))
        #expect(try await device.backend().appPreferences(Self.package, on: Self.device).asyncStorage?.unread == .format)
        #expect(device.scriptsRun == 1)
    }

    @Test("free space in an index page that still holds a table's values is cut out on the device")
    func staleBytesStayBehind() async throws {
        let source = try SQLiteFixture("reused.db")
        let stale = source.indexPages.contains { page in
            Data(source.database[((page - 1) * 4096)..<(page * 4096)]).range(of: Data("CANARY".utf8)) != nil
        }
        #expect(stale, "the fixture no longer has a value left in an index page")
        let (keys, device) = try await Self.read("reused.db")
        #expect(keys?.keys.count == 300)
        #expect(!device.output.contains(Self.hex("CANARY")))
    }

    @Test("the device itself refuses to print a table page, or a schema page that is not one")
    func deviceRefusesTablePages() throws {
        let device = try AppDataDevice()
        try device.install("legacy.db", as: "RKStorage")
        let source = try SQLiteFixture("legacy.db")
        let table = try #require((1...5).first { page in
            source.database[(page - 1) * 4096] == 13 && Data(source.database[((page - 1) * 4096)..<(page * 4096)]).range(of: Data("CANARY".utf8)) != nil
        })
        let asIndex = device.run(AndroidAsyncStorage.pagesScript(package: Self.package, store: Self.legacy, header: Self.layout.header, layout: Self.layout.bytes, schema: false, sources: [.init(log: false, offset: (table - 1) * 4096)]))
        let asSchema = device.run(AndroidAsyncStorage.pagesScript(package: Self.package, store: Self.legacy, header: Self.layout.header, layout: Self.layout.bytes, schema: true, sources: [.init(log: false, offset: (table - 1) * 4096)]))
        for result in [asIndex, asSchema] {
            #expect(result.stdout.contains("offsider: page refused") && result.stdout.contains("offsider: end"))
            #expect(!result.stdout.contains(Self.hex("CANARY")) && !result.stdout.contains("CANARY") && result.stderr.isEmpty)
        }
        let pastEnd = device.run(AndroidAsyncStorage.pagesScript(package: Self.package, store: Self.legacy, header: Self.layout.header, layout: Self.layout.bytes, schema: false, sources: [.init(log: false, offset: 1 << 30)]))
        #expect(pastEnd.stdout.contains("offsider: page short"))
    }

    @Test("a database that changes during the read is read once more; one that changes again is named, and the preference files still list")
    func changedDuringRead() async throws {
        let once = try AppDataDevice()
        try once.install("legacy.db", as: "RKStorage")
        once.beforeCall = { [once] call in if call == 2 { try? once.install("empty.db", as: "RKStorage") } }
        #expect(try await once.backend().appPreferences(Self.package, on: Self.device).asyncStorage == AppKeyStore(database: "RKStorage", keys: []))
        #expect(once.scriptsRun == 4)

        let twice = try AppDataDevice()
        try twice.install("legacy.db", as: "RKStorage")
        try twice.writePreferences("app.xml", "<map>\n    <string name=\"kept\">x</string>\n</map>\n")
        twice.beforeCall = { [twice] call in try? twice.install(call % 2 == 0 ? "empty.db" : "legacy.db", as: "RKStorage") }
        let preferences = try await twice.backend().appPreferences(Self.package, on: Self.device)
        #expect(preferences.asyncStorage == AppKeyStore(database: "RKStorage", keys: [], unread: .changing))
        #expect(preferences.files.map(\.name) == ["app.xml"] && preferences.keyCount == 1)
    }

    @Test("a write the app has not finished is not read around")
    func unfinishedWrite() async throws {
        let device = try AppDataDevice()
        try device.install("legacy.db", as: "RKStorage")
        try Data(AndroidAsyncStorage.journalMagic + [0, 0, 0, 1]).write(to: device.databases.appendingPathComponent("RKStorage-journal"))
        #expect(try await device.backend().appPreferences(Self.package, on: Self.device).asyncStorage?.unread == .unfinished)
        #expect(device.scriptsRun == 1)
    }

    @Test("a read the device does not answer leaves the preference listing whole")
    func failedReadKeepsPreferences() async throws {
        let device = try AppDataDevice()
        try device.install("legacy.db", as: "RKStorage")
        try device.writePreferences("app.xml", "<map>\n    <int name=\"count\" value=\"3\" />\n</map>\n")
        let answered = Counter()
        let backend = try AndroidAppLifecycleTests.setUp { command in
            answered.next() == 1 ? FakeAdbServer.shell(stdout: device.run(command).stdout) : FakeAdbServer.shell(stdout: "\(SQLiteFixture.canary)\n", stderr: "sh: \(SQLiteFixture.canary)\n", status: 2)
        }.0
        let preferences = try await backend.appPreferences(Self.package, on: Self.device)
        #expect(preferences.files == [AppPreferenceFile(name: "app.xml", keys: [.init(name: "count", type: "int")])])
        #expect(preferences.asyncStorage == AppKeyStore(database: "RKStorage", keys: [], unread: .failed))
    }

    @Test("a preference file named to look like a database's stamp is not taken for one")
    func forgedStamp() async throws {
        let device = try AppDataDevice()
        let forged = "offsider: storage RKStorage h=53514c69 w=0 l= j="
        try device.writePreferences("a\noffsider: done\n\(forged)\n.xml", "<map></map>\n")
        #expect(try await device.backend().appPreferences(Self.package, on: Self.device).asyncStorage == nil)
        #expect(device.scriptsRun == 1)

        try device.install("legacy.db", as: "RKStorage")
        let real = try await device.backend().appPreferences(Self.package, on: Self.device).asyncStorage
        #expect(real?.keys.contains("offsider-fixture-theme") == true && real?.unread == nil)
    }

    @Test("the device prints no page once the file's page size is not the one the offsets were worked out for")
    func layoutChanged() throws {
        let device = try AppDataDevice()
        try device.install("deep.db", as: "RKStorage")
        let source = try SQLiteFixture("deep.db")
        let index = try #require(source.indexPages.first)
        let result = device.run(AndroidAsyncStorage.pagesScript(package: Self.package, store: Self.legacy, header: Self.layout.header, layout: Self.layout.bytes, schema: false, sources: [.init(log: false, offset: 0), .init(log: false, offset: (index - 1) * 512)]))
        #expect(!result.stdout.contains("offsider: page") && result.stdout.contains("offsider: storage RKStorage") && result.stdout.hasSuffix("offsider: end\n"))
        #expect(!device.reads.contains { $0.count >= 512 })
    }

    @Test("a database under AsyncStorage's name that is not its shape gives way to the other one")
    func fallsBackPastAnotherShape() async throws {
        let device = try AppDataDevice()
        try device.install("value-first.db", as: "AsyncStorage")
        try device.install("legacy.db", as: "RKStorage")
        let store = try #require(try await device.backend().appPreferences(Self.package, on: Self.device).asyncStorage)
        #expect(store.database == "RKStorage" && store.unread == nil && store.other == "AsyncStorage" && store.keys.contains("offsider-fixture-theme"))
        #expect(!device.output.contains(Self.hex("CANARY")))

        let neither = try AppDataDevice()
        try neither.install("value-first.db", as: "AsyncStorage")
        try neither.install("utf16.db", as: "RKStorage")
        let first = try await neither.backend().appPreferences(Self.package, on: Self.device).asyncStorage
        #expect(first == AppKeyStore(database: "AsyncStorage", keys: [], unread: .schema, other: "RKStorage"))
    }

    @Test("a log frame header that comes back short fails the read, so stale pages are never read as current")
    func shortFrameHeader() async throws {
        let device = try AppDataDevice()
        try device.install("wal.db", as: "AsyncStorage")
        let probe = device.run(AndroidAppPackage.prefsScript(package: Self.package, then: AndroidAsyncStorage.probe)).stdout
        let stamp = try #require(AndroidAsyncStorage.stamps(afterPreferences: probe).first)
        let store = await AndroidAsyncStorage.read(stamp, store: Self.room, package: Self.package) { script in
            let lines = device.run(script).stdout.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.map { $0.hasPrefix("offsider: frame ") && $0.hasSuffix(lines.first { $0.hasPrefix("offsider: frame ") }?.suffix(8) ?? "") ? String($0.dropLast(2)) : String($0) }.joined(separator: "\n")
        }
        #expect(store == AppKeyStore(database: "AsyncStorage", keys: [], unread: .failed))
    }

    @Test("an app with no database costs no extra call; one with both lists the newer and names the other")
    func whichDatabase() async throws {
        let none = try AppDataDevice()
        #expect(try await none.backend().appPreferences(Self.package, on: Self.device).asyncStorage == nil)
        #expect(none.scriptsRun == 1)

        let both = try AppDataDevice()
        try both.install("legacy.db", as: "RKStorage")
        try both.install("room.db", as: "AsyncStorage")
        let store = try #require(try await both.backend().appPreferences(Self.package, on: Self.device).asyncStorage)
        #expect(store.database == "AsyncStorage" && store.other == "RKStorage" && store.keys.contains("third"))
        #expect(both.scriptsRun == 3)
    }

    @Test("each script reaches the app through run-as alone, with numbers as its only arguments")
    func scripts() {
        let pages = AndroidAsyncStorage.pagesScript(package: Self.package, store: Self.legacy, header: Self.layout.header, layout: Self.layout.bytes, schema: false, sources: [.init(log: false, offset: 8192), .init(log: true, offset: 4176)])
        let frames = AndroidAsyncStorage.framesScript(package: Self.package, store: Self.room, pageSize: 4096, count: 3)
        let probe = AndroidAppPackage.prefsScript(package: Self.package, then: AndroidAsyncStorage.probe)
        for script in [pages, frames, probe] {
            #expect(script.hasPrefix("run-as '\(Self.package)' sh -c "))
            for word in ["cat ", "sqlite3", "strings", "base64", "dd "] { #expect(!script.contains(word), "\(word)") }
        }
        #expect(pages.contains("p RKStorage 8192\np RKStorage-wal 4176\n"))
    }

    @Test("a reply out of shape is no page: a refusal, a gap that does not add up, or anything but hex")
    func pageReplies() {
        #expect(AndroidAsyncStorage.page("0a000000010ffc00:4092:0102030f", pageSize: 4096, usable: 4096)?.count == 4096)
        #expect(AndroidAsyncStorage.page("0a00:4:0102", pageSize: 8, usable: 6) == [0x0a, 0, 0, 0, 1, 2, 0, 0])
        #expect(AndroidAsyncStorage.page("0a00:6:00000000", pageSize: 8, usable: 8) == nil)
        #expect(AndroidAsyncStorage.page("0a00:2:0000000000", pageSize: 8, usable: 8) == nil)
        #expect(AndroidAsyncStorage.page("refused", pageSize: 8, usable: 8) == nil)
        #expect(AndroidAsyncStorage.page("0g:2:000000000000", pageSize: 8, usable: 8) == nil)
        #expect(AndroidAsyncStorage.page("0a00:-2:00", pageSize: 8, usable: 8) == nil)
        #expect(AndroidAsyncStorage.stamps(afterPreferences: "offsider: done\noffsider: storage Other h= w=0 l= j=\noffsider: storage RKStorage h=zz w=0 l= j=\n").isEmpty)
        #expect(AndroidAsyncStorage.stamps(afterPreferences: "offsider: done\noffsider: storage RKStorage h=00 w=7 l= j=\n").map(\.logBytes) == [7])
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }
}
