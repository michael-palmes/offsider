import Foundation
import OffsiderCore
import Testing
@testable import Offsider

private let screens = [
    UIFrame(x: 0, y: 0, width: 375, height: 667),
    UIFrame(x: 0, y: 0, width: 440, height: 956),
    UIFrame(x: 0, y: 0, width: 874, height: 402),
    UIFrame(x: 0, y: 0, width: 1376, height: 1032),
]

private let landscapeAppFrame = UIFrame(x: 0, y: 0, width: 874, height: 402)

/// A phone's screen in dp, as Android reports it.
private let androidPhone = UIFrame(x: 0, y: 0, width: 411.4, height: 923.4)

private func isInside(_ point: UIPoint, _ frame: UIFrame) -> Bool {
    (frame.x...(frame.x + frame.width)).contains(point.x) && (frame.y...(frame.y + frame.height)).contains(point.y)
}

@Suite("Gesture preset geometry")
struct GesturePresetGeometryTests {
    enum Edge: Sendable {
        case left, right, top, bottom
    }

    private func inset(of point: UIPoint, from edge: Edge, of frame: UIFrame) -> Double {
        switch edge {
        case .left: return point.x - frame.x
        case .right: return frame.x + frame.width - point.x
        case .top: return point.y - frame.y
        case .bottom: return frame.y + frame.height - point.y
        }
    }

    @Test("every preset starts and ends on screen, portrait or landscape", arguments: GesturePreset.swipes, screens)
    func presetStaysOnScreen(preset: GesturePreset, screen: UIFrame) {
        let (start, end) = preset.endpoints(in: screen)

        #expect(isInside(start, screen))
        #expect(isInside(end, screen))
    }

    @Test("scroll presets travel 200 points through the middle of a window away from the origin", arguments: [
        (GesturePreset.scrollUp, 0.0, -200.0),
        (GesturePreset.scrollDown, 0.0, 200.0),
        (GesturePreset.scrollLeft, -200.0, 0.0),
        (GesturePreset.scrollRight, 200.0, 0.0),
    ])
    func scrollCrossesMiddle(preset: GesturePreset, travelX: Double, travelY: Double) {
        let window = UIFrame(x: 100, y: 40, width: 600, height: 800)

        let (start, end) = preset.endpoints(in: window)

        #expect((start.x + end.x) / 2 == 400)
        #expect((start.y + end.y) / 2 == 440)
        #expect(end.x - start.x == travelX)
        #expect(end.y - start.y == travelY)
    }

    @Test("left and right edge swipes start within 20 points of their edge and end within 20 of the opposite one", arguments: [
        (GesturePreset.swipeFromLeftEdge, Edge.left, Edge.right),
        (GesturePreset.swipeFromRightEdge, Edge.right, Edge.left),
    ], screens)
    func sideEdgeSwipeCrossesScreen(edges: (preset: GesturePreset, from: Edge, to: Edge), screen: UIFrame) {
        let (start, end) = edges.preset.endpoints(in: screen)

        #expect(inset(of: start, from: edges.from, of: screen) <= 20)
        #expect(inset(of: end, from: edges.to, of: screen) <= 20)
    }

    @Test("top and bottom edge swipes start on the very edge, where system edge gestures begin, and travel well past the middle", arguments: [
        (GesturePreset.swipeFromTopEdge, Edge.top, Edge.bottom),
        (GesturePreset.swipeFromTopRightEdge, Edge.top, Edge.bottom),
        (GesturePreset.swipeFromBottomEdge, Edge.bottom, Edge.top),
    ], screens + [androidPhone])
    func verticalEdgeSwipeStartsOnEdge(edges: (preset: GesturePreset, from: Edge, to: Edge), screen: UIFrame) {
        let (start, end) = edges.preset.endpoints(in: screen)

        #expect(inset(of: start, from: edges.from, of: screen) <= 2)
        #expect(inset(of: start, from: edges.from, of: screen) > 0)
        #expect((0.2...0.4).contains(inset(of: end, from: edges.to, of: screen) / screen.height))
        #expect(start.x == end.x)
    }

    @Test("the top preset starts left of centre, clear of a Dynamic Island, and the top-right preset right of it, clear of the corner", arguments: screens + [androidPhone])
    func topPresetsSplitTheEdge(screen: UIFrame) {
        let left = GesturePreset.swipeFromTopEdge.endpoints(in: screen).start
        let right = GesturePreset.swipeFromTopRightEdge.endpoints(in: screen).start

        #expect((0.15...0.35).contains((left.x - screen.x) / screen.width))
        #expect((0.7...0.9).contains((right.x - screen.x) / screen.width))
    }

    @Test("top and bottom swipes span the reported screen, so an app frame that stops short of an edge still starts at it; left, right and scrolls keep the app frame", arguments: [
        (UISize(width: 402, height: 874), UIFrame(x: 0, y: 0, width: 402, height: 874)),
        (UISize(width: 874, height: 402), UIFrame(x: 62, y: 0, width: 750, height: 402)),
        (UISize(width: 411.4, height: 923.4), UIFrame(x: 0, y: 24, width: 411.4, height: 851.4)),
    ])
    func edgeSwipesSpanScreen(screen: UISize, app: UIFrame) throws {
        let whole = UIFrame(x: 0, y: 0, width: screen.width, height: screen.height)

        for preset in GesturePreset.swipes {
            let frame = try #require(preset.frame(screen: screen, viewport: app, applicationFrame: app, width: nil, height: nil))
            #expect(frame == (preset.spansScreen ? whole : app), "\(preset.rawValue)")
        }
    }

    @Test("left and right swipes start at a windowed app's own edge, where its back swipe begins, not the screen's")
    func sideSwipesKeepWindow() throws {
        let window = UIFrame(x: 300, y: 100, width: 600, height: 800)

        let frame = try #require(GesturePreset.swipeFromLeftEdge.frame(screen: UISize(width: 1376, height: 1032), viewport: window, applicationFrame: window, width: nil, height: nil))

        #expect(GesturePreset.swipeFromLeftEdge.endpoints(in: frame).start.x == 320)
    }

    @Test("without a reported screen, top and bottom swipes use the tree's viewport, then the app frame; with neither there is no frame")
    func edgeSwipeFallbacks() {
        let viewport = UIFrame(x: 0, y: 0, width: 411.4, height: 923.4)
        let app = UIFrame(x: 0, y: 24, width: 411.4, height: 851.4)

        #expect(GesturePreset.swipeFromTopEdge.frame(screen: nil, viewport: viewport, applicationFrame: app, width: nil, height: nil) == viewport)
        #expect(GesturePreset.swipeFromTopEdge.frame(screen: UISize(width: 0, height: 0), viewport: viewport, applicationFrame: app, width: nil, height: nil) == viewport)
        #expect(GesturePreset.swipeFromTopEdge.frame(screen: nil, viewport: nil, applicationFrame: app, width: nil, height: nil) == app)
        #expect(GesturePreset.swipeFromTopEdge.frame(screen: nil, viewport: nil, applicationFrame: nil, width: 400, height: 800) == nil)
    }

    @Test("--screen-width and --screen-height replace the screen's size for a bottom swipe")
    func overridesReplaceScreenSize() {
        let frame = GesturePreset.swipeFromBottomEdge.frame(screen: UISize(width: 402, height: 874), viewport: nil, applicationFrame: nil, width: 430, height: nil)

        #expect(frame == UIFrame(x: 0, y: 0, width: 430, height: 874))
    }

    @Test("explicit width and height replace the app frame's size and keep its origin")
    func overridesReplaceSize() {
        let app = UIFrame(x: 100, y: 40, width: 402, height: 874)

        #expect(GesturePreset.screen(applicationFrame: app, width: 430, height: 932) == UIFrame(x: 100, y: 40, width: 430, height: 932))
        #expect(GesturePreset.screen(applicationFrame: app, width: 430, height: nil) == UIFrame(x: 100, y: 40, width: 430, height: 874))
        #expect(GesturePreset.screen(applicationFrame: app, width: nil, height: 700) == UIFrame(x: 100, y: 40, width: 402, height: 700))
        #expect(GesturePreset.screen(applicationFrame: app, width: nil, height: nil) == app)
    }
}

/// A simulator rotated to landscape on 402 x 874 point portrait hardware.
@MainActor
private final class LandscapeBackend: DeviceBackend {
    let applicationFrame: UIFrame?
    let screen: UISize?

    init(applicationFrame: UIFrame?, screen: UISize? = nil) {
        self.applicationFrame = applicationFrame
        self.screen = screen
    }

    var platform: DevicePlatform { .ios }
    func prepare() async throws {}
    func listDevices() async throws -> [DeviceSummary] { [] }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Landscape") }
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        let roots = applicationFrame.map { [UINode(role: .application, frame: $0, native: .ios(IOSNativeAttributes()))] } ?? []
        return UITree(platform: platform, device: id.rawValue, roots: roots)
    }
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? {
        screen.map { UIScreenInfo(width: $0.width, height: $0.height) }
    }
    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        tree: UITree?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)] {
        points.map {
            OrientationCoordinateMath.translateToPhysical(
                x: $0.x,
                y: $0.y,
                orientation: .landscape,
                portraitWidth: 402,
                portraitHeight: 874
            )
        }
    }
    func openInputSession(for id: DeviceID) async throws -> any InputSession { RecordingInputSession() }
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {}
    func screenshotPNG(for id: DeviceID) async throws -> Data { Data() }
    func volatileScreenBands(for id: DeviceID) async -> ScreenBands { ScreenBands(top: 0, bottom: 0) }
}

private struct UnexpectedPrimitives: Error {}

@Suite("Gesture input on a rotated simulator")
@MainActor
struct GestureRotatedInputTests {
    private func gestureEvent(_ arguments: [String], applicationFrame: UIFrame?, screen: UISize? = nil) async throws -> InputEvent {
        let device = DeviceID(rawValue: "LANDSCAPE", platform: .ios)
        let context = BatchContext(
            backend: LandscapeBackend(applicationFrame: applicationFrame, screen: screen),
            device: device,
            axCachePolicy: .perBatch,
            typeSubmissionMode: .composite,
            typeChunkSize: 1
        )
        let gesture = try Gesture.parse(arguments + ["--device", device.rawValue])
        let primitives = try await gesture.toBatchPrimitives(context: context, logger: OffsiderLogger())
        guard primitives.count == 1, case .hidMergeable(let event) = primitives[0] else {
            throw UnexpectedPrimitives()
        }
        return event
    }

    @Test("scroll-up is centred on the landscape app frame and rotated onto the portrait hardware")
    func landscapeScrollIsCentredAndRotated() async throws {
        let event = try await gestureEvent(["scroll-up"], applicationFrame: landscapeAppFrame)

        #expect(event == .swipe(301, yStart: 437, xEnd: 101, yEnd: 437, delta: 25, duration: 0.5))
    }

    @Test("a --screen-width override replaces the app frame width and is still rotated")
    func screenWidthOverrideIsRotated() async throws {
        let event = try await gestureEvent(["swipe-from-left-edge", "--screen-width", "800"], applicationFrame: landscapeAppFrame)

        #expect(event == .swipe(201, yStart: 854, xEnd: 201, yEnd: 94, delta: 50, duration: GesturePreset.swipeFromLeftEdge.defaultDuration))
    }

    @Test("swipe-from-bottom-edge starts 2 points above the reported screen's bottom edge, below an app frame that stops short of it")
    func bottomEdgeStartsAtScreenEdge() async throws {
        let event = try await gestureEvent(["swipe-from-bottom-edge"], applicationFrame: UIFrame(x: 62, y: 0, width: 750, height: 380), screen: UISize(width: 874, height: 402))

        guard case let .swipe(xStart, yStart, _, _, _, _) = event else {
            Issue.record("expected a swipe, got \(event)")
            return
        }
        let start = OrientationCoordinateMath.translateToPhysical(x: 437, y: 400, orientation: .landscape, portraitWidth: 402, portraitHeight: 874)
        #expect(xStart == start.x)
        #expect(yStart == start.y)
    }

    @Test("long-press-drag holds 800 ms at the press, then moves to the end in 60 steps over 0.6 s, without reading the tree")
    func longPressDrag() async throws {
        let device = DeviceID(rawValue: "LANDSCAPE", platform: .ios)
        let context = BatchContext(backend: LandscapeBackend(applicationFrame: nil), device: device, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)
        let gesture = try Gesture.parse(["long-press-drag", "--x", "100", "--y", "200", "--to-x", "300", "--to-y", "200", "--device", device.rawValue])
        let primitives = try await gesture.toBatchPrimitives(context: context, logger: OffsiderLogger())
        guard primitives.count == 1, case .hidMergeable(.composite(let events)) = primitives[0] else {
            Issue.record("expected one composite, got \(primitives)")
            return
        }
        let start = OrientationCoordinateMath.translateToPhysical(x: 100, y: 200, orientation: .landscape, portraitWidth: 402, portraitHeight: 874)
        #expect(events.first == .touch(direction: .down, x: start.x, y: start.y))
        #expect(events.dropFirst().first == .delay(0.8))
        #expect(events.filter { if case .touch(.down, _, _) = $0 { return true } else { return false } }.count == 61)
        let moves = events.compactMap { if case .delay(let seconds) = $0 { return seconds } else { return nil } }.dropFirst().dropLast()
        #expect(abs(moves.reduce(0, +) - 0.6) < 1e-9)
    }

    @Test("pinch puts two fingers --from apart about the centre, moves them to --to over the duration in about 60 moves a second, then lifts both")
    func pinch() async throws {
        let device = DeviceID(rawValue: "LANDSCAPE", platform: .ios)
        let context = BatchContext(backend: LandscapeBackend(applicationFrame: nil), device: device, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)
        let gesture = try Gesture.parse(["pinch", "--from", "60", "--to", "240", "--x", "300", "--y", "200", "--duration", "0.5", "--device", device.rawValue])
        let primitives = try await gesture.toBatchPrimitives(context: context, logger: OffsiderLogger())
        guard primitives.count == 1, case .hidMergeable(.composite(let events)) = primitives[0] else {
            Issue.record("expected one composite, got \(primitives)")
            return
        }
        func physical(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            OrientationCoordinateMath.translateToPhysical(x: x, y: y, orientation: .landscape, portraitWidth: 402, portraitHeight: 874)
        }
        let (a, b) = (physical(270, 200), physical(330, 200))
        let (c, d) = (physical(180, 200), physical(420, 200))
        #expect(events.first == .twoFingerTouch(direction: .down, x1: a.x, y1: a.y, x2: b.x, y2: b.y))
        #expect(events.last == .twoFingerTouch(direction: .up, x1: c.x, y1: c.y, x2: d.x, y2: d.y))
        let downs = events.filter { if case .twoFingerTouch(.down, _, _, _, _) = $0 { return true } else { return false } }
        #expect(downs.count == 31)
        #expect(downs.last == .twoFingerTouch(direction: .down, x1: c.x, y1: c.y, x2: d.x, y2: d.y))
        let pauses = events.compactMap { if case .delay(let seconds) = $0 { return seconds } else { return nil } }
        #expect(abs(pauses.reduce(0, +) - 0.5) < 1e-9)
    }

    @Test("pinch centres on the app frame's middle by default, and a finger off the screen is a usage error before anything is sent")
    func pinchCentreAndBounds() async throws {
        let frames = GesturePreset.pinchFrames(centre: UIPoint(x: 100, y: 50), from: 40, to: 20, moves: 2)
        #expect(frames.map { $0.0.x } == [80, 85, 90] && frames.map { $0.1.x } == [120, 115, 110])
        #expect(GesturePreset.pinchMoves(duration: 0.1) == 10 && GesturePreset.pinchMoves(duration: 10) == 240)

        let device = DeviceID(rawValue: "LANDSCAPE", platform: .ios)
        let backend = LandscapeBackend(applicationFrame: UIFrame(x: 0, y: 0, width: 874, height: 402), screen: UISize(width: 874, height: 402))
        let context = BatchContext(backend: backend, device: device, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)
        let centred = try Gesture.parse(["pinch", "--from", "100", "--to", "50", "--device", device.rawValue])
        guard case .hidMergeable(.composite(let events)) = try await centred.toBatchPrimitives(context: context, logger: OffsiderLogger()).first else {
            Issue.record("expected a composite")
            return
        }
        let (left, right) = (OrientationCoordinateMath.translateToPhysical(x: 387, y: 201, orientation: .landscape, portraitWidth: 402, portraitHeight: 874),
                             OrientationCoordinateMath.translateToPhysical(x: 487, y: 201, orientation: .landscape, portraitWidth: 402, portraitHeight: 874))
        #expect(events.first == .twoFingerTouch(direction: .down, x1: left.x, y1: left.y, x2: right.x, y2: right.y))

        let offscreen = try Gesture.parse(["pinch", "--from", "60", "--to", "500", "--x", "100", "--y", "100", "--device", device.rawValue])
        let error = await #expect(throws: CLIError.self) { _ = try await offscreen.toBatchPrimitives(context: context, logger: OffsiderLogger()) }
        #expect(error?.reason == .usage)
        #expect(error?.userFacingDescription.contains("off the screen") == true)
        #expect(error?.userFacingDescription.contains("--from and --to") == true)
    }

    @Test("a tree without an application frame fails with an actionable error")
    func missingApplicationFrameFails() async throws {
        let error = await #expect(throws: CLIError.self) {
            try await gestureEvent(["scroll-up"], applicationFrame: nil)
        }

        #expect(error?.errorDescription?.contains("no application frame") == true)
        #expect(error?.errorDescription?.contains("offsider doctor --device LANDSCAPE") == true)
    }
}

@Suite("Gesture options")
struct GestureOptionTests {
    @Test("long-press-drag needs its points, swipes refuse them, and --hold-ms stays in range", arguments: [
        (["long-press-drag", "--x", "1", "--y", "2", "--to-x", "3"], "long-press-drag needs --to-y."),
        (["scroll-up", "--x", "1"], "--x applies to long-press-drag only."),
        (["scroll-up", "--hold-ms", "500"], "--hold-ms applies to long-press-drag only."),
        (["long-press-drag", "--x", "1", "--y", "2", "--to-x", "3", "--to-y", "4", "--hold-ms", "10001"], "--hold-ms must be from 0 to 10000"),
        (["long-press-drag", "--x", "1", "--y", "2", "--to-x", "3", "--to-y", "4", "--delta", "5"], "--delta applies to swipe presets only"),
        (["long-press-drag", "--x", "1", "--y", "2", "--to-x", "1", "--to-y", "2"], "must be different"),
        (["pinch", "--from", "60"], "pinch needs --from and --to"),
        (["pinch", "--from", "60", "--to", "60"], "must differ"),
        (["pinch", "--from", "10", "--to", "200"], "--from must be from 20 to 600"),
        (["pinch", "--from", "60", "--to", "700"], "--to must be from 20 to 600"),
        (["pinch", "--from", "60", "--to", "200", "--x", "100"], "both --x and --y"),
        (["pinch", "--from", "60", "--to", "200", "--to-x", "100"], "--to-x does not apply to pinch"),
        (["pinch", "--from", "60", "--to", "200", "--duration", "0.05"], "from 0.1 to 10 seconds"),
        (["scroll-up", "--from", "60"], "--from and --to apply to pinch only"),
    ])
    func validation(arguments: [String], message: String) {
        let error = #expect(throws: (any Error).self) { try Gesture.parse(arguments + ["--device", "emulator-5554"]) }
        #expect(error.map { Gesture.message(for: $0).contains(message) } == true, "\(error.map { Gesture.message(for: $0) } ?? "")")
    }
}
