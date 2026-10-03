import Foundation
import OffsiderCore
@testable import Offsider

/// A scripted backend: serves `trees` and `screenshots` in order, holding the last, and records input.
@MainActor
final class FakeDeviceBackend: DeviceBackend {
    let platform: DevicePlatform
    let trees: [UITree]
    let screenshots: [Data]
    let screen: UIScreenInfo?
    let session: RecordingInputSession
    let advanceTreeOnInput: Bool
    var bands = ScreenBands(top: 0, bottom: 0)
    /// Called on every tree read, before the tree is served.
    var onTreeRead: (() -> Void)?

    private(set) var treeIndex = 0
    private(set) var screenshotIndex = 0
    private(set) var treeReads = 0
    private(set) var screenshotReads = 0
    private(set) var coordinateCalls: [(count: Int, hadTree: Bool)] = []
    private(set) var openedSessions: [DeviceID] = []
    private(set) var detachedTouches: [[DetachedTouchStep]] = []
    /// What `displays(of:)` serves; one main display unless a test sets a foldable's.
    var displayList = DisplayList(
        displays: [DisplayInfo(
            descriptor: DisplayDescriptor(role: .main, platformId: "1", name: "LCD", pixelWidth: 1206, pixelHeight: 2622, scale: 3, nativeOrientation: 0),
            pointWidth: 402, pointHeight: 874, rotationDegrees: 0, active: true
        )],
        posture: nil
    )
    /// Posture reads in order, holding the last; empty serves `displayList.posture`.
    var postures: [Posture?] = []
    var postureRequestError: (any Error)?
    private(set) var requestedPostures: [Posture] = []
    private(set) var capturedDisplays: [String?] = []

    /// With `advanceTreeOnInput` the tree moves on after each performed event; otherwise after each read. A nil `session` makes a new one.
    init(
        platform: DevicePlatform = .ios,
        trees: [UITree],
        screenshots: [Data] = [],
        screen: UIScreenInfo? = nil,
        session: RecordingInputSession? = nil,
        advanceTreeOnInput: Bool = false
    ) {
        self.platform = platform
        self.trees = trees
        self.screenshots = screenshots
        self.screen = screen
        let session = session ?? RecordingInputSession()
        self.session = session
        self.advanceTreeOnInput = advanceTreeOnInput
        if advanceTreeOnInput {
            session.onPerform = { [unowned self] _ in
                treeIndex = min(treeIndex + 1, max(trees.count - 1, 0))
            }
        }
    }

    /// The tree the next read serves.
    var currentTree: UITree? {
        trees.isEmpty ? nil : trees[min(treeIndex, trees.count - 1)]
    }

    private func readTree(for id: DeviceID) -> UITree {
        onTreeRead?()
        treeReads += 1
        let tree = currentTree ?? UITree(platform: platform, device: id.rawValue, roots: [])
        if !advanceTreeOnInput {
            treeIndex = min(treeIndex + 1, max(trees.count - 1, 0))
        }
        return tree
    }

    func prepare() async throws {}
    func listDevices() async throws -> [DeviceSummary] { [] }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Fake") }

    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        var tree = readTree(for: id)
        if let point {
            tree.roots = tree.deepestNode(at: point).map { [$0] } ?? []
        }
        return tree
    }

    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { screen }

    /// Identity; on iOS without a tree it reads one, as the real backend does for the application frame.
    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        tree: UITree?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)] {
        coordinateCalls.append((count: points.count, hadTree: tree != nil))
        if platform == .ios, tree == nil {
            _ = readTree(for: id)
        }
        return points
    }

    func openInputSession(for id: DeviceID) async throws -> any InputSession {
        openedSessions.append(id)
        return session
    }

    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        detachedTouches.append(steps)
    }

    func screenshotPNG(for id: DeviceID) async throws -> Data {
        screenshotReads += 1
        guard !screenshots.isEmpty else {
            throw CLIError(errorDescription: "no screenshot scripted")
        }
        let data = screenshots[min(screenshotIndex, screenshots.count - 1)]
        screenshotIndex = min(screenshotIndex + 1, screenshots.count - 1)
        return data
    }

    func volatileScreenBands(for id: DeviceID) async -> ScreenBands { bands }
}

extension FakeDeviceBackend: DisplayControlling, PostureControlling, DisplayCapturing {
    func displays(of id: DeviceID) async throws -> DisplayList { displayList }

    func posture(of id: DeviceID) async throws -> Posture? {
        guard !postures.isEmpty else { return displayList.posture }
        return postures.count > 1 ? postures.removeFirst() : postures[0]
    }

    func requestPosture(_ posture: Posture, on id: DeviceID) async throws {
        requestedPostures.append(posture)
        if let postureRequestError { throw postureRequestError }
    }

    func screenshotPNG(for id: DeviceID, display: String?) async throws -> Data {
        capturedDisplays.append(display)
        return try await screenshotPNG(for: id)
    }
}

/// Small builders for trees in unit tests.
enum FakeUI {
    static func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> UIFrame {
        UIFrame(x: x, y: y, width: width, height: height)
    }

    static func node(
        _ role: UIRole,
        id: String? = nil,
        label: String? = nil,
        value: String? = nil,
        frame: UIFrame? = nil,
        enabled: Bool? = nil,
        state: UIState = UIState(),
        platform: DevicePlatform = .ios,
        children: [UINode] = []
    ) -> UINode {
        let native: UINative = platform == .ios
            ? .ios(IOSNativeAttributes())
            : .android(AndroidNativeAttributes(resourceId: id))
        return UINode(
            role: role, id: id, label: label, value: value, frame: frame,
            enabled: enabled, state: state, native: native, children: children
        )
    }

    /// One `.application` root at the origin, `width` by `height`, holding `children`.
    static func tree(
        platform: DevicePlatform = .ios,
        device: String = "fake-device",
        width: Double = 402,
        height: Double = 874,
        label: String? = "Playground",
        _ children: [UINode] = []
    ) -> UITree {
        let root = node(.application, label: label, frame: frame(0, 0, width, height), platform: platform, children: children)
        return UITree(platform: platform, device: device, roots: [root])
    }
}
