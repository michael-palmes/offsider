import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A host clock the test moves: each delay the session performs and each screenshot advance it.
@MainActor
private final class HoldClock {
    var now: Duration = .zero
    func advance(_ milliseconds: Int) { now += .milliseconds(milliseconds) }
}

@Suite("Screenshots during a held gesture")
@MainActor
struct HoldScreenshotTests {
    private static let start = ["--start-x", "200", "--start-y", "800", "--end-x", "200", "--end-y", "400"]
    private static let press = InputEvent.touch(direction: .down, x: 200, y: 800)
    private static let lift = InputEvent.touch(direction: .up, x: 200, y: 400)

    private static func swipe(_ arguments: [String]) throws -> Swipe {
        try Swipe.parse(start + arguments + ["--device", "emulator-5554"])
    }

    private static func drag(_ arguments: [String]) throws -> Drag {
        try Drag.parse(start + arguments + ["--device", "emulator-5554"])
    }

    private static func report(_ path: String) -> ScreenshotReport {
        ScreenshotReport(path: path, width: 10, height: 20, pixelsPerPoint: 1, region: nil, orientation: nil, upright: true, format: .png)
    }

    /// A session whose delays move `clock`, as the device would take that long.
    private static func session(_ clock: HoldClock, failingOn event: InputEvent? = nil) -> RecordingInputSession {
        let session = RecordingInputSession(failingOn: event)
        session.onPerform = { event in
            if case .delay(let seconds) = event { clock.advance(Int((seconds * 1000).rounded())) }
            if case .composite(let events) = event, case .delay(let seconds)? = events.first { clock.advance(Int((seconds * 1000).rounded())) }
        }
        return session
    }

    // MARK: - Options

    @Test("a screenshot after the --hold-end the caller set is a usage error naming the fix", arguments: ["swipe", "drag"])
    func afterHoldEnd(command: String) {
        let arguments = ["--hold-end", "500", "--screenshot-at", "200", "--screenshot-at", "800"]
        let error = #expect(throws: (any Error).self) {
            if command == "swipe" { _ = try Self.swipe(arguments) } else { _ = try Self.drag(arguments) }
        }
        #expect(error.map { Swipe.message(for: $0).contains("--screenshot-at 800 comes after --hold-end 500. Raise --hold-end to 800") } == true)
    }

    @Test("--screenshot-at outside 0 to 10000 is a usage error", arguments: ["-1", "10001"])
    func offsetRange(value: String) {
        let error = #expect(throws: (any Error).self) { try Self.swipe(["--screenshot-at=\(value)"]) }
        #expect(error.map { Swipe.message(for: $0).contains("--screenshot-at must be from 0 to 10000; got \(value).") } == true)
    }

    @Test("more than 10 screenshots is a usage error")
    func tooMany() {
        let error = #expect(throws: (any Error).self) { try Self.drag((0...10).flatMap { ["--screenshot-at", "\($0 * 10)"] }) }
        #expect(error.map { Swipe.message(for: $0).contains("--screenshot-at takes at most 10 screenshots; got 11.") } == true)
    }

    @Test("--output without --screenshot-at is a usage error")
    func outputAlone() {
        let error = #expect(throws: (any Error).self) { try Self.swipe(["--output", "shot.png"]) }
        #expect(error.map { Swipe.message(for: $0).contains("--output applies to --screenshot-at only.") } == true)
    }

    @Test("without --hold-end the finger rests until the last screenshot; drag never rests less than its default")
    func holdStretches() throws {
        #expect(try Self.drag(["--screenshot-at", "800", "--screenshot-at", "300"]).finalHoldMilliseconds == 800)
        #expect(try Self.drag(["--screenshot-at", "10"]).finalHoldMilliseconds == Drag.defaultHoldEndMilliseconds)
        #expect(try Self.drag(["--hold-end", "1200", "--screenshot-at", "300"]).finalHoldMilliseconds == 1200)
        #expect(try Self.drag([]).finalHoldMilliseconds == Drag.defaultHoldEndMilliseconds)
        #expect(try Self.swipe(["--screenshot-at", "300"]).holdShots.holdEnd(given: nil, fallback: 0) == 300)
    }

    @Test("one screenshot goes to --output as given; several are numbered before the extension")
    func outputNames() throws {
        #expect(try Self.swipe(["--screenshot-at", "0", "--output", "shots/scrub.png"]).holdShots.outputPath(for: 0) == "shots/scrub.png")
        let two = try Self.swipe(["--screenshot-at", "0", "--screenshot-at", "500", "--output", "shots/scrub.png"]).holdShots
        #expect(two.outputPath(for: 0) == "shots/scrub-1.png")
        #expect(two.outputPath(for: 1) == "shots/scrub-2.png")
        let bare = try Self.swipe(["--screenshot-at", "0", "--screenshot-at", "500", "--output", "shots/scrub"]).holdShots
        #expect(bare.outputPath(for: 1) == "shots/scrub-2")
        let folder = try Self.swipe(["--screenshot-at", "0", "--screenshot-at", "500", "--output", "shots/"]).holdShots
        #expect(folder.outputPath(for: 1) == "shots/")
        #expect(try Self.swipe(["--screenshot-at", "0"]).holdShots.outputPath(for: 0) == nil)
    }

    @Test("the press stops at the end with the finger down; the plain gesture adds only the hold and the lift")
    func pressIsTheGestureWithoutItsEnd() throws {
        let drag = try Self.drag(["--hold-ms", "800", "--hold-end", "300"])
        let full = try drag.dragEvent(from: (x: 200, y: 800), to: (x: 200, y: 400))
        guard case .composite(let press) = try drag.pressEvent(from: (x: 200, y: 800), to: (x: 200, y: 400)), case .composite(let events) = full else {
            Issue.record("expected composites")
            return
        }
        #expect(press.last == .touch(direction: .down, x: 200, y: 400))
        #expect(events == press + [.delay(0.3), Self.lift])

        let swipe = try Self.swipe(["--hold-end", "300"])
        guard case .composite(let swipePress) = try swipe.pressEvent(from: (x: 200, y: 800), to: (x: 200, y: 400)),
              case .composite(let swipeEvents) = try swipe.swipeEvent(from: (x: 200, y: 800), to: (x: 200, y: 400)) else {
            Issue.record("expected composites")
            return
        }
        #expect(swipeEvents == swipePress + [.delay(0.3), Self.lift])
    }

    // MARK: - Timing

    @Test("each screenshot waits for its offset with the finger down, and the lift comes at --hold-end")
    func screenshotsOnTime() async throws {
        let clock = HoldClock()
        let session = Self.session(clock)
        var shots: [HeldScreenshot] = []
        var callsAtShot: [Int] = []
        let capture = HoldCapture(offsets: [200, 600], holdEnd: 1000, uptime: { clock.now })

        let held = try await capture.perform(press: Self.press, lift: Self.lift, on: session) { index in
            callsAtShot.append(session.calls.count)
            clock.advance(150)
            return Self.report("shot-\(index).png")
        } taken: { shots.append($0) }

        #expect(session.calls == [
            .perform(Self.press), .perform(.delay(0.2)), .perform(.delay(0.25)), .perform(.composite([.delay(0.25), Self.lift])),
        ])
        #expect(callsAtShot == [2, 3])
        #expect(shots.map(\.atMs) == [200, 600])
        #expect(shots.map(\.startMs) == [200, 600])
        #expect(shots.map(\.endMs) == [350, 750])
        #expect(held == 1000)
    }

    @Test("a screenshot that overruns the next offset or --hold-end keeps the finger down, and the hold says so")
    func overrun() async throws {
        let clock = HoldClock()
        let session = Self.session(clock)
        var shots: [HeldScreenshot] = []
        let capture = HoldCapture(offsets: [0, 100], holdEnd: 300, uptime: { clock.now })

        let held = try await capture.perform(press: Self.press, lift: Self.lift, on: session) { _ in
            clock.advance(400)
            return Self.report("shot.png")
        } taken: { shots.append($0) }

        #expect(session.calls == [.perform(Self.press), .perform(Self.lift)])
        #expect(shots.map(\.startMs) == [0, 400])
        #expect(held == 800)
    }

    @Test("a failed screenshot lifts the finger before the error goes up, and keeps what was taken")
    func failedScreenshotLifts() async throws {
        let clock = HoldClock()
        let session = Self.session(clock)
        var shots: [HeldScreenshot] = []
        let capture = HoldCapture(offsets: [0, 100], holdEnd: 500, uptime: { clock.now })

        await #expect(throws: FakeInputSessionError.self) {
            _ = try await capture.perform(press: Self.press, lift: Self.lift, on: session) { index in
                if index == 1 { throw FakeInputSessionError() }
                return Self.report("shot.png")
            } taken: { shots.append($0) }
        }
        #expect(session.calls.last == .perform(Self.lift))
        #expect(shots.count == 1)
    }

    @Test("a failed press sends no lift of its own")
    func failedPress() async throws {
        let clock = HoldClock()
        let session = Self.session(clock, failingOn: Self.press)
        let capture = HoldCapture(offsets: [0], holdEnd: 0, uptime: { clock.now })
        var shoots = 0

        await #expect(throws: FakeInputSessionError.self) {
            _ = try await capture.perform(press: Self.press, lift: Self.lift, on: session) { _ in
                shoots += 1
                return Self.report("shot.png")
            } taken: { _ in }
        }
        #expect(session.calls == [.perform(Self.press)])
        #expect(shoots == 0)
    }

    // MARK: - Capture

    @Test("the screenshot reads the tree while the finger is down and paints the password field it finds")
    func masksDuringHold() async throws {
        let device = DeviceID(rawValue: "fake-device", platform: .ios)
        let backend = FakeDeviceBackend(
            trees: [FakeUI.tree(width: 390, height: 844, [SecureTextTests.passwordField()])],
            screenshots: [try ScreenshotMaskTests.whitePNG()],
            screen: ScreenshotMaskTests.screen
        )
        var callsAtRead: [Int] = []
        backend.onTreeRead = { callsAtRead.append(backend.session.calls.count) }
        let path = ScreenshotMaskTests.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let swipe = try Swipe.parse(Self.start + ["--screenshot-at", "0", "--output", path, "--device", device.rawValue])
        let details = InputDetails()

        try await swipe.holdShots.perform(press: Self.press, lift: Self.lift, holdEnd: 0, on: DeviceRouter.Route(backend: backend, device: device), details: details)

        #expect(callsAtRead == [1])
        #expect(backend.session.calls == [.perform(Self.press), .perform(Self.lift)])
        #expect(details.screenshots.count == 1)
        #expect(details.screenshots.first?.report.path == path)
        #expect(details.screenshots.first?.report.masked == 1)
        let image = try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(ScreenshotMaskTests.pixel(image, 600, 870) == ScreenshotMaskTests.black)
    }

    @Test("--json lists the hold and each screenshot with its timing beside the screenshot's own fields")
    func json() throws {
        let line = InputReport(
            command: "swipe", target: "(200, 800) to (200, 400)", dispatched: .yes,
            holdMs: 1000, screenshots: [HeldScreenshot(atMs: 200, startMs: 203, endMs: 410, report: Self.report("/tmp/scrub.png"))]
        ).jsonLine()

        #expect(line.contains(#""holdMs":1000,"screenshots":[{"atMs":200,"startMs":203,"endMs":410,"path":"/tmp/scrub.png","width":10,"height":20"#))
        #expect(!InputReport(command: "swipe", target: "x", dispatched: .yes).jsonLine().contains("screenshots"))
    }

    @Test("a batch swipe or drag step with --screenshot-at is refused before anything is sent", arguments: ["swipe", "drag"])
    func batchRefuses(command: String) async throws {
        let device = DeviceID(rawValue: "STUB", platform: .ios)
        let session = RecordingInputSession()
        let context = BatchContext(backend: StubBackend(session: session), device: device, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)
        let arguments = ["--screenshot-at", "100"]

        let error = await #expect(throws: (any Error).self) {
            if command == "swipe" {
                _ = try await Self.swipe(arguments).toBatchPrimitives(context: context, logger: OffsiderLogger())
            } else {
                _ = try await Self.drag(arguments).toBatchPrimitives(context: context, logger: OffsiderLogger())
            }
        }
        #expect(error.map { Swipe.message(for: $0) } == HoldScreenshotOptions.batchMessage)
        #expect(session.calls.isEmpty)
    }
}
