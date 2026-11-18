import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A Turnstile history in its own temporary root, on a wall clock a test moves.
final class TurnstileHistoryFixture: @unchecked Sendable {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    let root: String
    private let lock = NSLock()
    private var date = TurnstileHistoryFixture.start

    init() {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-turnstile-test-\(UUID().uuidString)")
    }

    var now: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }

    var history: TurnstileHistory {
        let root = root
        return TurnstileHistory(root: { root }, now: { self.now })
    }

    var directory: String { (root as NSString).appendingPathComponent(TurnstileHistory.directoryName) }

    func path(platform: DevicePlatform = .android, device: String) -> String {
        (directory as NSString).appendingPathComponent(TurnstileHistory.fileName(platform: platform, device: device))
    }

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        try await TurnstileHistory.$current.withValue(history) { try await body() }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// Gives each test a fresh temporary Turnstile history, so no test reads or writes Offsider's private directory.
struct TurnstileHistoryScope: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let fixture = TurnstileHistoryFixture()
        defer { fixture.remove() }
        try await fixture.run { try await function() }
    }
}

extension Trait where Self == TurnstileHistoryScope {
    static var turnstileHistory: Self { TurnstileHistoryScope() }
}

@Suite("Turnstile history", .turnstileHistory)
struct TurnstileHistoryTests {
    private let start = TurnstileHistoryFixture.start

    @Test("a screen with no widget starts no record, the same state writes nothing, and a pass is kept through the reset after it")
    func nextRecord() {
        #expect(TurnstileRecord.next(previous: nil, state: .absent, now: start) == nil)

        let box = TurnstileRecord.next(previous: nil, state: .checkbox, now: start + 0.7)
        #expect(box == TurnstileRecord(state: .checkbox, since: start))
        #expect(TurnstileRecord.next(previous: box, state: .checkbox, now: start + 30) == nil)

        let passed = TurnstileRecord.next(previous: box, state: .passed, now: start + 40)
        #expect(passed == TurnstileRecord(state: .passed, since: start + 40, lastPassed: start + 40))
        let reset = TurnstileRecord.next(previous: passed, state: .checkbox, now: start + 400)
        #expect(reset == TurnstileRecord(state: .checkbox, since: start + 400, lastPassed: start + 40))
        #expect(TurnstileRecord.next(previous: reset, state: .absent, now: start + 500)?.lastPassed == start + 40)
    }

    @Test("a record a day old or dated ahead of the clock is dropped, and so is a pass a day old")
    func lifetime() {
        let day = TurnstileRecord.lifetime
        let record = TurnstileRecord(state: .checkbox, since: start, lastPassed: start - 600)
        #expect(record.usable(now: start + day - 1) == TurnstileRecord(state: .checkbox, since: start))
        #expect(record.usable(now: start + day) == nil)
        #expect(record.usable(now: start - 3600) == nil)
        #expect(record.usable(now: start + 60) == record)
        #expect(TurnstileRecord.next(previous: record, state: .checkbox, now: start + day) == TurnstileRecord(state: .checkbox, since: start + day))
    }

    @Test("the file holds the state and two times and nothing else, and anything else reads as no record")
    func fileFormat() throws {
        let record = TurnstileRecord(state: .checkbox, since: start, lastPassed: start - 75)
        let text = String(decoding: record.encoded(), as: UTF8.self)
        #expect(text == #"{"v":1,"state":"checkbox","since":"2027-01-15T08:00:00Z","lastPassed":"2027-01-15T07:58:45Z"}"#)
        #expect(TurnstileRecord(data: record.encoded()) == record)
        #expect(TurnstileRecord(data: TurnstileRecord(state: .absent, since: start).encoded())?.lastPassed == nil)
        for bad in [
            #"{"v":2,"state":"checkbox","since":"2027-01-15T08:00:00Z"}"#,
            #"{"v":1,"state":"ticked","since":"2027-01-15T08:00:00Z"}"#,
            #"{"v":1,"state":"checkbox","since":"yesterday"}"#,
            #"{"v":1,"state":"checkbox","since":"2027-01-15T08:00:00Z","lastPassed":"soon"}"#,
        ] {
            #expect(TurnstileRecord(data: Data(bad.utf8)) == nil, "\(bad)")
        }
    }

    @Test("a read writes only when the state changes, into a private file whose name holds no device id")
    @MainActor
    func writesOnlyOnChange() throws {
        let fixture = TurnstileHistoryFixture()
        defer { fixture.remove() }
        let history = fixture.history
        let device = "emulator-5554"

        #expect(history.note(.absent, platform: .android, device: device) == TurnstileRecord(state: .absent, since: start))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory))

        history.note(.checkbox, platform: .android, device: device)
        let path = fixture.path(device: device)
        let first = try inode(path)
        fixture.now = start + 5
        #expect(history.note(.checkbox, platform: .android, device: device) == TurnstileRecord(state: .checkbox, since: start))
        #expect(try inode(path) == first)

        fixture.now = start + 9
        #expect(history.note(.passed, platform: .android, device: device).lastPassed == start + 9)
        #expect(try inode(path) != first)
        #expect(history.record(platform: .android, device: device) == TurnstileRecord(state: .passed, since: start + 9, lastPassed: start + 9))
        #expect(history.record(platform: .ios, device: device) == nil)

        #expect(try mode(fixture.directory) == 0o700)
        #expect(try mode(path) == 0o600)
        #expect(!(path as NSString).lastPathComponent.contains("5554"))
    }

    @Test("a day-old record is removed when read, and a write sweeps other devices' day-old files")
    @MainActor
    func staleFilesGo() throws {
        let fixture = TurnstileHistoryFixture()
        defer { fixture.remove() }
        let history = fixture.history
        history.note(.checkbox, platform: .android, device: "emulator-5554")
        history.note(.checkbox, platform: .android, device: "emulator-5556")
        let old = fixture.path(device: "emulator-5556")
        try FileManager.default.setAttributes([.modificationDate: Date() - 2 * TurnstileRecord.lifetime], ofItemAtPath: old)

        fixture.now = start + TurnstileRecord.lifetime
        #expect(history.record(platform: .android, device: "emulator-5554") == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.path(device: "emulator-5554")))

        fixture.now = start + 60
        history.note(.checkbox, platform: .android, device: "emulator-5554")
        #expect(!FileManager.default.fileExists(atPath: old))
    }

    @Test("an oversized file at the record's path is no record, and the next change replaces it")
    @MainActor
    func untrustedFile() throws {
        let fixture = TurnstileHistoryFixture()
        defer { fixture.remove() }
        let history = fixture.history
        history.note(.checkbox, platform: .android, device: "emulator-5554")
        let path = fixture.path(device: "emulator-5554")
        try Data(repeating: 0x20, count: TurnstileRecord.maximumBytes + 1).write(to: URL(fileURLWithPath: path))
        #expect(history.record(platform: .android, device: "emulator-5554") == nil)

        history.note(.verifying, platform: .android, device: "emulator-5554")
        #expect(history.record(platform: .android, device: "emulator-5554")?.state == .verifying)
    }

    private func inode(_ path: String) throws -> UInt64 {
        var info = stat()
        try #require(lstat(path, &info) == 0)
        return info.st_ino
    }

    private func mode(_ path: String) throws -> mode_t {
        var info = stat()
        try #require(lstat(path, &info) == 0)
        return info.st_mode & 0o777
    }
}
