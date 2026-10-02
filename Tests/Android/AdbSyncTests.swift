import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("adb sync")
struct AdbSyncTests {
    static let path = "/data/local/tmp/offsider-helper-0123456789abcdef.dex"

    static func server(_ session: FakeSyncSession, maxReadChunk: Int = .max) -> FakeAdbServer {
        FakeAdbServer(maxReadChunk: maxReadChunk, handler: FakeAdbServer.devices(["emulator-5556"]) { _, service in
            service == "sync:" ? .session(session) : FakeAdbServer.fail("unexpected \(service)")
        })
    }

    static func push(_ bytes: Data, through server: FakeAdbServer, to path: String = path, mtime: UInt32 = 1_700_000_000) async throws {
        try await AdbClient(endpoint: .defaultAdbServer, connector: server)
            .push(bytes, to: path, mtime: mtime, on: "emulator-5556", timeout: .seconds(5))
    }

    @Test("SEND carries the path and the mode in decimal after a little-endian length")
    func sendFraming() throws {
        #expect(try AdbSync.send(path: "/data/local/tmp/a.dex", mode: 0o100644)
            == Data("SEND".utf8) + Data([27, 0, 0, 0]) + Data("/data/local/tmp/a.dex,33188".utf8))

        let long = "/data/local/tmp/" + String(repeating: "x", count: 284)
        #expect(try AdbSync.send(path: long, mode: 0o100755).prefix(8) == Data("SEND".utf8) + Data([0x32, 0x01, 0, 0]))
    }

    @Test("a path over 1024 bytes is refused before any connection")
    func longPathRefused() async {
        let server = Self.server(FakeSyncSession())
        await #expect(throws: AndroidError.self) {
            try await Self.push(Data("dex".utf8), through: server, to: "/data/local/tmp/" + String(repeating: "x", count: 1020))
        }
        #expect(server.connectionAttempts == 0)
    }

    @Test("a 150 KiB file goes as three DATA chunks of at most 64 KiB, then DONE with the mtime, then QUIT")
    func pushInChunks() async throws {
        let file = Data((0..<(150 * 1024)).map { UInt8($0 % 251) })
        let session = FakeSyncSession()
        let server = Self.server(session)

        try await Self.push(file, through: server, mtime: 0x6543_2100)

        #expect(server.services == ["host:transport:emulator-5556", "sync:"])
        #expect(session.requests == [
            .send(Self.path + ",33188"), .data(65536), .data(65536), .data(22528), .done(mtime: 0x6543_2100), .quit,
        ])
        #expect(session.file == file)
        let written = session.bytesWritten
        let firstData = 8 + Self.path.utf8.count + 6
        #expect(Data(written.dropFirst(firstData).prefix(8)) == Data("DATA".utf8) + Data([0x00, 0x00, 0x01, 0x00]))
        #expect(Data(written.dropFirst(firstData + 2 * (8 + 65536)).prefix(8)) == Data("DATA".utf8) + Data([0x00, 0x58, 0x00, 0x00]))
        let done: Data = Data("DONE".utf8) + Data([0x00, 0x21, 0x43, 0x65])
        let quit: Data = Data("QUIT".utf8) + Data([0, 0, 0, 0])
        #expect(Data(written.suffix(16)) == done + quit)
        #expect(server.closedStreams == 1)
    }

    @Test("an empty file is SEND then DONE, with no DATA")
    func emptyFile() async throws {
        let session = FakeSyncSession()
        try await Self.push(Data(), through: Self.server(session), mtime: 7)
        #expect(session.requests == [.send(Self.path + ",33188"), .done(mtime: 7), .quit])
    }

    @Test("OKAY and FAIL replies decode only once whole, and only their own bytes are consumed")
    func replyDecoding() throws {
        let okay = Data("OKAY".utf8) + Data([0, 0, 0, 0])
        let fail = Data("FAIL".utf8) + Data([7, 0, 0, 0]) + Data("no room".utf8)
        for cut in 0..<okay.count {
            #expect(try AdbSync.reply(from: okay.prefix(cut))?.reply == nil)
        }
        for cut in 0..<fail.count {
            #expect(try AdbSync.reply(from: fail.prefix(cut))?.reply == nil)
        }
        let afterOkay = try AdbSync.reply(from: okay + Data("QUIT".utf8))
        #expect(afterOkay?.reply == .okay)
        #expect(afterOkay?.consumed == 8)
        let afterFail = try AdbSync.reply(from: fail + Data("x".utf8))
        #expect(afterFail?.reply == .fail("no room"))
        #expect(afterFail?.consumed == 15)
    }

    @Test("a reply that is neither OKAY nor FAIL is a protocol error")
    func unknownReply() {
        let error = #expect(throws: AndroidError.self) {
            try AdbSync.reply(from: Data("DENT".utf8) + Data([0, 0, 0, 0]))
        }
        #expect(error?.kind == .adbProtocol)
    }

    @Test("an OKAY split across reads completes the push")
    func okaySplitAcrossReads() async throws {
        let session = FakeSyncSession()
        try await Self.push(Data("dex".utf8), through: Self.server(session, maxReadChunk: 3))
        #expect(session.requests.last == .quit)
        #expect(session.file == Data("dex".utf8))
    }

    @Test("a FAIL reply, even split across reads, is adbCommandFailed with the device's message")
    func failReply() async {
        let session = FakeSyncSession { _, _ in .fail("couldn't create file: Permission denied") }
        let server = Self.server(session, maxReadChunk: 3)
        let error = await #expect(throws: AndroidError.self) {
            try await Self.push(Data("dex".utf8), through: server, to: "/system/x.dex")
        }
        #expect(error?.kind == .adbCommandFailed)
        #expect(error?.message == "`push /system/x.dex` failed on emulator-5556: couldn't create file: Permission denied.")
        #expect(!session.requests.contains(.quit))
        #expect(server.closedStreams == 1)
    }

    @Test("a device that hangs up or stays silent after DONE fails the push, naming it")
    func noReply() async {
        let hungUp = await #expect(throws: AndroidError.self) {
            try await Self.push(Data("dex".utf8), through: Self.server(FakeSyncSession { _, _ in .hangUp }), to: "/data/local/tmp/x.dex")
        }
        #expect(hungUp?.message == "`push /data/local/tmp/x.dex` failed on emulator-5556: the device closed the sync connection before confirming the push.")

        let server = Self.server(FakeSyncSession { _, _ in .silence })
        let silent = await #expect(throws: AndroidError.self) {
            try await Self.push(Data("dex".utf8), through: server, to: "/data/local/tmp/x.dex")
        }
        #expect(silent?.message == "`push /data/local/tmp/x.dex` failed on emulator-5556: no answer within 5 s.")
        #expect(server.closedStreams == 1)
    }
}
