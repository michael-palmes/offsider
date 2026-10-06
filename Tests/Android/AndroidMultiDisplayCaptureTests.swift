import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android capture on a phone with several displays")
@MainActor
struct AndroidMultiDisplayCaptureTests {
    static let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)
    static let inner = GalaxyFoldFixtures.innerId
    static let cover = GalaxyFoldFixtures.coverId

    /// The signature and an IHDR naming the size, which is all the capture path reads of a PNG.
    nonisolated static func png(_ width: Int, _ height: Int) -> Data {
        func word(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (24 - $0 * 8) & 0xFF) } }
        return Data(AndroidScreenCapture.pngSignature + word(13) + Array("IHDR".utf8) + word(width) + word(height) + [8, 6, 0, 0, 0])
    }

    /// A hinge a test can fold by hand partway through a command.
    final class Hinge: @unchecked Sendable {
        private let lock = NSLock()
        private var isClosed: Bool
        init(closed: Bool) { isClosed = closed }
        var closed: Bool {
            get { lock.withLock { isClosed } }
            set { lock.withLock { isClosed = newValue } }
        }
    }

    static func fold(closed: Bool, picks: String?, raw: Data? = nil) -> FakeAdbServer {
        fold(Hinge(closed: closed), picks: picks, raw: raw)
    }

    /// A Galaxy Z Fold whose `screencap` without `-d` warns, then captures `picks`, or the active panel when nil, as the Fold does; folded, its cover captures at the `wm size` override.
    static func fold(_ hinge: Hinge, picks: String?, raw: Data? = nil) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(["R58M123ABC"], host: Self.host) { _, service in
            let closed = hinge.closed
            let innerPNG = png(1768, 2208)
            let coverPNG = closed ? png(840, 2289) : png(832, 2268)
            let picked = picks ?? (closed ? cover : inner)
            switch service {
            case "exec:screencap -p": return FakeAdbServer.exec(ScreencapRawTests.warning + (picked == inner ? innerPNG : coverPNG))
            case "exec:screencap -d \(inner) -p": return FakeAdbServer.exec(innerPNG)
            case "exec:screencap -d \(cover) -p": return FakeAdbServer.exec(coverPNG)
            case "exec:screencap": return FakeAdbServer.exec(ScreencapRawTests.warning + (raw ?? Data()))
            case "exec:screencap -d \(cover)": return FakeAdbServer.exec(raw ?? Data())
            default: break
            }
            switch String(service.dropFirst("shell,v2,raw:".count)) {
            case AndroidDeviceState.printStates: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.printStates)
            case AndroidDeviceState.readState: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.state(closed: closed))
            case AndroidDisplayList.command: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.dumpsys(closed: closed))
            case AndroidDisplayStatus.script: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.status(closed: closed))
            case AndroidDisplayGeometry.probeScript: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.geometry(closed: closed))
            default: return FakeAdbServer.shell(stderr: "unexpected", status: 1)
            }
        })
    }

    static let host: @Sendable (String) -> FakeAdbServer.Reply = { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang }

    static func backend(_ server: FakeAdbServer, environment: [String: String] = [:]) throws -> AndroidBackend {
        AndroidBackend(host: AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), environment: environment, adb: server)) { _, _ in }
    }

    static func execs(_ server: FakeAdbServer) -> [String] {
        server.services.filter { $0.hasPrefix("exec:") }
    }

    @Test("unfolded, screencap's own pick has the inner panel's size, so it is kept capture after capture without -d")
    func unfoldedKeepsOwnPick() async throws {
        let server = Self.fold(closed: false, picks: nil)
        let backend = try Self.backend(server)

        #expect(try await backend.screenshotPNG(for: Self.phone) == Self.png(1768, 2208))
        #expect(try await backend.screenshotPNG(for: Self.phone) == Self.png(1768, 2208))
        #expect(Self.execs(server) == ["exec:screencap -p", "exec:screencap -p"])
    }

    @Test("folded by hand mid-command, a phone whose screencap follows the active panel is read again and its new pick kept")
    func handFoldFollowsActivePanel() async throws {
        let hinge = Hinge(closed: false)
        let server = Self.fold(hinge, picks: nil)
        let backend = try Self.backend(server)

        #expect(try await backend.screenshotPNG(for: Self.phone) == Self.png(1768, 2208))
        hinge.closed = true
        #expect(try await backend.screenshotPNG(for: Self.phone) == Self.png(840, 2289))
        #expect(Self.execs(server) == ["exec:screencap -p", "exec:screencap -p"])
        #expect(server.services.filter { $0 == "shell,v2,raw:\(AndroidDisplayGeometry.probeScript)" }.count == 2)
    }

    @Test("folded, a pick of the dark inner panel is captured again from the cover, and later captures name the cover")
    func foldedRecapturesActivePanel() async throws {
        let server = Self.fold(closed: true, picks: Self.inner)
        let backend = try Self.backend(server)

        #expect(try await backend.screenshotPNG(for: Self.phone) == Self.png(840, 2289))
        #expect(try await backend.screenshotPNG(for: Self.phone) == Self.png(840, 2289))
        #expect(Self.execs(server) == ["exec:screencap -p", "exec:screencap -d \(Self.cover) -p", "exec:screencap -d \(Self.cover) -p"])
    }

    @Test("a probe still describing the panel just folded away does not approve screencap's pick of it")
    func laggingProbeDoesNotApprovePick() async throws {
        final class Probes: @unchecked Sendable {
            let lock = NSLock()
            var lagging = 1
            func next() -> String {
                lock.withLock {
                    defer { lagging = max(0, lagging - 1) }
                    return lagging > 0 ? FoldableFixtures.foldGeometryOpen : FoldableFixtures.foldGeometryClosed
                }
            }
        }
        let probes = Probes()
        let (inner, cover) = (FoldableFixtures.innerId, FoldableFixtures.coverId)
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["R58M123ABC"], host: Self.host) { _, service in
            switch service {
            case "exec:screencap -p": return FakeAdbServer.exec(ScreencapRawTests.warning + Self.png(2076, 2152))
            case "exec:screencap -d \(cover) -p": return FakeAdbServer.exec(Self.png(1080, 2424))
            case "exec:screencap -d \(inner) -p": return FakeAdbServer.exec(Self.png(2076, 2152))
            default: break
            }
            switch String(service.dropFirst("shell,v2,raw:".count)) {
            case AndroidDisplayStatus.script:
                return FakeAdbServer.shell(stdout: FoldableFixtures.status(FoldableFixtures.foldPrintStates, FoldableFixtures.foldStateClosed, FoldableFixtures.foldDumpsysClosed))
            case AndroidDisplayList.command: return FakeAdbServer.shell(stdout: FoldableFixtures.foldDumpsysClosed)
            case AndroidDisplayGeometry.probeScript: return FakeAdbServer.shell(stdout: probes.next())
            default: return FakeAdbServer.shell(stderr: "unexpected", status: 1)
            }
        })
        let backend = try Self.backend(server)

        #expect(try await backend.screenshotPNG(for: Self.phone) == Self.png(1080, 2424))
        #expect(Self.execs(server) == ["exec:screencap -p", "exec:screencap -d \(cover) -p"])
    }

    @Test("folded, a pick of the cover at its overridden logical size is kept")
    func foldedKeepsCoverAtOverride() async throws {
        let server = Self.fold(closed: true, picks: Self.cover)
        let backend = try Self.backend(server)

        #expect(try await backend.screenshotPNG(for: Self.phone) == Self.png(840, 2289))
        #expect(Self.execs(server) == ["exec:screencap -p"])
    }

    @Test("a phone with one display takes one plain screencap and reads no displays")
    func singleDisplayAddsNoCalls() async throws {
        let png = Self.png(1080, 2424)
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["R58M123ABC"], host: Self.host) { _, service in
            service == "exec:screencap -p" ? FakeAdbServer.exec(png) : FakeAdbServer.shell(stderr: "unexpected", status: 1)
        })
        let backend = try Self.backend(server)

        #expect(try await backend.screenshotPNG(for: Self.phone) == png)
        #expect(server.services.filter { $0.hasPrefix("exec:") || $0.hasPrefix("shell") } == ["exec:screencap -p"])
    }

    @Test("raw capture follows the active panel too: a pick of another size is captured again with -d")
    func rawRecapturesActivePanel() async throws {
        let server = Self.fold(closed: true, picks: Self.inner, raw: ScreencapRawTests.raw())
        let backend = try Self.backend(server, environment: ["OFFSIDER_ANDROID_CAPTURE": "raw"])

        let decoded = try AndroidScreenCaptureTests.labels(ofPNG: try await backend.screenshotPNG(for: Self.phone))
        #expect(decoded.width == 3 && decoded.height == 2)
        #expect(Self.execs(server) == ["exec:screencap", "exec:screencap -d \(Self.cover)"])
    }

    @Test("before any probe, the screen status names the lit panel and One UI's posture, not main")
    func screenStatusNamesLitPanel() async throws {
        for (closed, display, posture) in [(false, ScreenDisplay(id: "inner", platformId: Self.inner), Posture.open), (true, ScreenDisplay(id: "cover", platformId: Self.cover), .closed)] {
            let server = Self.fold(closed: closed, picks: Self.inner)
            let backend = try Self.backend(server)
            let status = await backend.screenStatus("R58M123ABC")
            #expect(status.display == display)
            #expect(status.posture == posture)
            #expect(!server.services.contains("shell,v2,raw:\(AndroidDisplayGeometry.probeScript)"))
        }
    }

    @Test("a failed capture reports screencap's own error, not its multi-display warning")
    func failureSkipsWarning() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(["R58M123ABC"], host: Self.host) { _, service in
            service == "exec:screencap -p"
                ? FakeAdbServer.exec(ScreencapRawTests.warning + Data("screencap: no display\n".utf8))
                : FakeAdbServer.shell(stderr: "unexpected", status: 1)
        })
        let backend = try Self.backend(server)

        let error = await #expect(throws: AndroidError.self) { try await backend.screenshotPNG(for: Self.phone) }
        #expect(error?.message == "`screencap -p` failed on R58M123ABC: screencap: no display.")
        #expect(AndroidScreenCapture.failureDetail(ScreencapRawTests.warning) == "no output")
    }

    @Test("an off panel on a phone is folded or unfolded by hand, not with offsider posture")
    func displayOffOnPhone() async throws {
        let backend = try Self.backend(Self.fold(closed: false, picks: Self.inner))

        let error = await #expect(throws: AndroidError.self) { try await backend.screenshotPNG(for: Self.phone, display: Self.cover) }
        #expect(error?.message == "The cover display (\(Self.cover)) of R58M123ABC is off (posture open), so it has nothing to capture. Fold the phone, then retry.")
    }
}
