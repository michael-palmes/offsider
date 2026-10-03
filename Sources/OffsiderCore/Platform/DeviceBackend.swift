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

extension DeviceBackend {
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
