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

    @Test("every preset starts and ends on screen, portrait or landscape", arguments: GesturePreset.allCases, screens)
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

    @Test("edge swipes start within 20 points of their edge and end within 20 of the opposite one", arguments: [
        (GesturePreset.swipeFromLeftEdge, Edge.left, Edge.right),
        (GesturePreset.swipeFromRightEdge, Edge.right, Edge.left),
        (GesturePreset.swipeFromTopEdge, Edge.top, Edge.bottom),
        (GesturePreset.swipeFromBottomEdge, Edge.bottom, Edge.top),
    ], screens)
    func edgeSwipeCrossesScreen(edges: (preset: GesturePreset, from: Edge, to: Edge), screen: UIFrame) {
        let (start, end) = edges.preset.endpoints(in: screen)

        #expect(inset(of: start, from: edges.from, of: screen) <= 20)
        #expect(inset(of: end, from: edges.to, of: screen) <= 20)
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

    init(applicationFrame: UIFrame?) {
        self.applicationFrame = applicationFrame
    }

    var platform: DevicePlatform { .ios }
    func prepare() async throws {}
    func listDevices() async throws -> [DeviceSummary] { [] }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Landscape") }
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        let roots = applicationFrame.map { [UINode(role: .application, frame: $0, native: .ios(IOSNativeAttributes()))] } ?? []
        return UITree(platform: platform, device: id.rawValue, roots: roots)
    }
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { nil }
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
    private func gestureEvent(_ arguments: [String], applicationFrame: UIFrame?) async throws -> InputEvent {
        let device = DeviceID(rawValue: "LANDSCAPE", platform: .ios)
        let context = BatchContext(
            backend: LandscapeBackend(applicationFrame: applicationFrame),
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

        #expect(event == .swipe(201, yStart: 854, xEnd: 201, yEnd: 94, delta: 50, duration: 0.3))
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
