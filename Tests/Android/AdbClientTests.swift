import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("adb client")
struct AdbClientTests {
    private static func client(_ server: FakeAdbServer) -> AdbClient {
        AdbClient(endpoint: .defaultAdbServer, connector: server)
    }

    @Test("host:version reads the hex payload after OKAY")
    func serverVersion() async throws {
        let server = FakeAdbServer { _ in FakeAdbServer.okay(payload: "0029") }
        #expect(try await Self.client(server).serverVersion() == 41)
        #expect(server.services == ["host:version"])
    }

    @Test("host:devices-l rows come back parsed")
    func devices() async throws {
        let server = FakeAdbServer { _ in FakeAdbServer.okay(payload: "emulator-5556 device product:x model:sdk_gphone64_arm64 transport_id:3\n") }
        let entries = try await Self.client(server).devices()
        #expect(entries.map(\.serial) == ["emulator-5556"])
        #expect(entries.first?.properties["model"] == "sdk_gphone64_arm64")
    }

    @Test("shell sends the transport, then shell,v2,raw, and keeps stdout, stderr and status apart")
    func shellSeparatesStreams() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in
            FakeAdbServer.shell(stdout: "out\r\nline\n", stderr: "err\n", status: 3)
        })
        let result = try await Self.client(server).shell("echo hi", on: "emulator-5556")

        #expect(server.services == ["host:transport:emulator-5556", "shell,v2,raw:echo hi"])
        #expect(result.stdoutText == "out\nline\n")
        #expect(result.stderrText == "err\n")
        #expect(result.status == 3)
    }

    @Test("replies split into tiny reads decode the same")
    func tinyReads() async throws {
        let server = FakeAdbServer(maxReadChunk: 3, handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in
            FakeAdbServer.shell(stdout: String(repeating: "x", count: 50), status: 0)
        })
        let result = try await Self.client(server).shell("true", on: "emulator-5556")
        #expect(result.stdoutText.count == 50)
        #expect(result.status == 0)
    }

    @Test("exec returns raw bytes until the end of the stream")
    func execReadsToEnd() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in FakeAdbServer.exec(png) })
        #expect(try await Self.client(server).exec("screencap -p", on: "emulator-5556") == png)
        #expect(server.services.last == "exec:screencap -p")
    }

    @Test("an unknown serial is reported as not running")
    func unknownSerial() async {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in FakeAdbServer.shell() })
        let error = await #expect(throws: AndroidError.self) {
            try await Self.client(server).shell("true", on: "emulator-5560")
        }
        #expect(error?.message == "No emulator with serial emulator-5560 is running. Run `offsider list-devices` to see running emulators.")
    }

    @Test("an offline device gets the offline message")
    func offlineDevice() async {
        let server = FakeAdbServer { _ in FakeAdbServer.fail("device offline") }
        let error = await #expect(throws: AndroidError.self) {
            try await Self.client(server).shell("true", on: "emulator-5556")
        }
        #expect(error?.kind == .deviceOffline)
    }

    @Test("a refused connection means no server, and a connect timeout means it stopped answering")
    func connectFailures() async {
        let refused = await #expect(throws: AndroidError.self) {
            try await Self.client(FakeAdbServer(connect: .refuse) { _ in .hang }).serverVersion()
        }
        #expect(refused?.kind == .adbServerNotRunning)

        let timedOut = await #expect(throws: AndroidError.self) {
            try await Self.client(FakeAdbServer(connect: .timeOut) { _ in .hang }).serverVersion()
        }
        #expect(timedOut?.message == "The adb server on 127.0.0.1:5037 did not answer within 1 s. Restart it with `adb kill-server && adb start-server`.")
    }

    @Test("a shell command that never answers fails with its name and the timeout")
    func shellTimeout() async {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in FakeAdbServer.okay })
        let error = await #expect(throws: AndroidError.self) {
            try await Self.client(server).shell("uiautomator dump", on: "emulator-5556", timeout: .seconds(20))
        }
        #expect(error?.message == "`uiautomator dump` failed on emulator-5556: no answer within 20 s.")
    }

    @Test("bytes that arrive with a service's OKAY are handed over in pending, and the stream carries on after them", arguments: [Int.max, 3])
    func earlyBytesArePending(maxReadChunk: Int) async throws {
        let early = Data("exit packet and more".utf8)
        let server = FakeAdbServer(maxReadChunk: maxReadChunk, handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in
            .bytes(Data("OKAY".utf8) + early, thenClose: true)
        })
        let opened = try await Self.client(server).openService("shell,v2,raw:exit 90", on: "emulator-5556", timeout: .seconds(2))

        var received = opened.pending
        while case let chunk = try await opened.stream.read(upTo: 64, deadline: .now + .seconds(1)), !chunk.isEmpty {
            received.append(chunk)
        }
        await opened.stream.close()

        #expect(!opened.pending.isEmpty)
        #expect(received == early)
    }

    @Test("a quiet service opens with nothing pending and stays open for the caller")
    func quietServiceStaysOpen() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in FakeAdbServer.okay })
        let opened = try await Self.client(server).openService("sync:", on: "emulator-5556", timeout: .seconds(2))

        #expect(opened.pending.isEmpty)
        #expect(server.services == ["host:transport:emulator-5556", "sync:"])
        #expect(server.closedStreams == 0)
        await opened.stream.close()
    }

    @Test("a refused service is an error naming it, and its connection is closed")
    func refusedService() async {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in FakeAdbServer.fail("closed") })
        let error = await #expect(throws: AndroidError.self) {
            _ = try await Self.client(server).openService("localabstract:offsider-x", on: "emulator-5556", timeout: .seconds(2))
        }
        #expect(error?.message == "`localabstract:offsider-x` failed on emulator-5556: closed.")
        #expect(server.closedStreams == 1)
    }

    @Test("every service connection is closed, on success and on failure")
    func connectionsAreClosed() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["emulator-5556"]) { _, _ in FakeAdbServer.shell() })
        let client = Self.client(server)
        _ = try await client.shell("true", on: "emulator-5556")
        _ = try? await client.shell("true", on: "emulator-5999")
        #expect(server.closedStreams == 2)
    }
}
