import Foundation

public struct BootedDevice: Sendable {
    public let id: DeviceID
    public let name: String

    public init(id: DeviceID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Touch steps that must outlive the process, such as `touch --down` now and `touch --up` later.
public enum DetachedTouchStep: Equatable, Sendable {
    case down(x: Double, y: Double)
    case up(x: Double, y: Double)
    case hold(TimeInterval)
}

/// One platform's device access for a single command run; backends hold the logger.
@MainActor
public protocol DeviceBackend: AnyObject {
    var platform: DevicePlatform { get }
    /// What `devices` says it skipped when this backend cannot list: `iOS Simulators`, `iPhones and iPads`.
    var listingName: String { get }
    func prepare() async throws
    func listDevices() async throws -> [DeviceSummary]
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice
    /// The frontmost app's tree, or with `point` the element there as the only root; `screen` is left nil.
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree
    /// For `describe-ui` only; nil when the platform cannot report it.
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo?
    /// The screen's size alone, for a bounds check that does not need the display or posture; nil when the platform cannot report it.
    func screenSize(for id: DeviceID) async throws -> UISize?
    /// Logical points to input-space points; `tree` reuses an accessibility tree the caller already holds.
    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        tree: UITree?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)]
    func openInputSession(for id: DeviceID) async throws -> any InputSession
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws
    func screenshotPNG(for id: DeviceID) async throws -> Data
    /// Portrait bands `--verify` leaves out of screenshot comparisons.
    func volatileScreenBands(for id: DeviceID) async -> ScreenBands
    /// Ends what the backend started for the command, once, after success or failure; returns within a few seconds.
    func close() async
}

/// A backend with more than one way to capture a device's screen, which says how it took the latest screenshot.
@MainActor
public protocol CaptureSourceReporting: AnyObject {
    /// `stream` or `devicectl` on an iPhone or iPad; nil before the first capture.
    func captureSource(for id: DeviceID) -> String?
}

/// A backend whose screenshot masks read more of the screen than its tree output shows.
@MainActor
public protocol MaskTreeReading: AnyObject {
    /// The frontmost app's tree for painting masks; never cached or shown.
    func maskTree(for id: DeviceID) async throws -> UITree
    /// Starts what `maskTree` reads through, so a read inside a held gesture does not wait for it.
    func prepareMaskTree(for id: DeviceID) async throws
}

extension MaskTreeReading {
    public func prepareMaskTree(for id: DeviceID) async throws {}
}

extension DeviceBackend {
    public var listingName: String { platform.devicesName }

    public func close() async {}

    public func screenSize(for id: DeviceID) async throws -> UISize? {
        try await screenInfo(for: id).map { UISize(width: $0.width, height: $0.height) }
    }

    public func accessibilityTree(for id: DeviceID) async throws -> UITree {
        try await accessibilityTree(for: id, point: nil)
    }

    /// Opens a session, performs one event and closes the session, on failure too.
    public func perform(_ event: InputEvent, on id: DeviceID) async throws {
        let session = try await openInputSession(for: id)
        do {
            try await session.perform(event)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }
}

/// Optional capability: the platform's own hit-test, which knows what is drawn on top; only the iOS simulator has one.
@MainActor
public protocol PointHitTesting: DeviceBackend {
    /// The element a touch at `point` reaches, as the platform reports it; nil when nothing answers there.
    /// An empty screen-sized group from a process outside a non-empty `appPIDs`, such as a prompt's backdrop, is answered at once.
    func hitTest(at point: UIPoint, on id: DeviceID, appPIDs: Set<Int>) async throws -> UINode?
    /// The name of the process a hit's `pid` belongs to, such as `SafariViewService`; nil when it cannot tell.
    func processName(of pid: Int, on id: DeviceID) async -> String?
}

extension PointHitTesting {
    public func hitTest(at point: UIPoint, on id: DeviceID) async throws -> UINode? {
        try await hitTest(at: point, on: id, appPIDs: [])
    }
}

/// Optional capability: one read of the element at a point, never retried, so describe-ui and a missed wait can tell what the screen shows that the tree does not; only the iOS simulator has one.
@MainActor
public protocol PresentationProbing: DeviceBackend {
    /// The element at `point` with its process id; nil when nothing answers there.
    func probe(at point: UIPoint, on id: DeviceID) async throws -> UINode?
}

/// Optional capability: the platform's own tree reply before mapping, for the committed tree goldens.
@MainActor
public protocol RawAccessibilitySource: DeviceBackend {
    func rawAccessibilitySource(for id: DeviceID) async throws -> Data
}

/// Optional capability: raw pixel streaming for `stream-video --format bgra`.
@MainActor
public protocol RawVideoStreaming: DeviceBackend {
    func streamBGRA(
        from id: DeviceID,
        fps: Int,
        quality: Int,
        scale: Double,
        to fileDescriptor: Int32,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws
}

/// Optional capability: a string that changes when the device boots again, so a cached tree from an earlier boot is ignored.
@MainActor
public protocol BootMarking: DeviceBackend {
    func bootMarker(for id: DeviceID) async -> String?
}
