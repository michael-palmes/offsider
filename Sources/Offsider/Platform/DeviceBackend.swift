import Foundation
import OffsiderCore

enum DevicePlatform: String, Sendable {
    case ios
    case android
}

struct DeviceID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    let platform: DevicePlatform

    var description: String { rawValue }
}

struct BootedDevice: Sendable {
    let id: DeviceID
    let name: String
}

/// Touch steps that must outlive the process, such as `touch --down` now and `touch --up` later.
enum DetachedTouchStep: Equatable, Sendable {
    case down(x: Double, y: Double)
    case up(x: Double, y: Double)
    case hold(TimeInterval)
}

/// One platform's device access for a single command run; backends hold the logger.
@MainActor
protocol DeviceBackend: AnyObject {
    var platform: DevicePlatform { get }
    func prepare() async throws
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice
    func accessibilityJSON(for id: DeviceID, point: AccessibilityPoint?) async throws -> Data
    /// Logical points to input-space points; `roots` reuses an accessibility tree the caller already holds.
    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        roots: [AccessibilityElement]?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)]
    func openInputSession(for id: DeviceID) async throws -> any InputSession
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws
    func screenshotPNG(for id: DeviceID) async throws -> Data
}

extension DeviceBackend {
    func accessibilityRoots(for id: DeviceID) async throws -> [AccessibilityElement] {
        let jsonData = try await accessibilityJSON(for: id, point: nil)
        let decoder = JSONDecoder()

        if let roots = try? decoder.decode([AccessibilityElement].self, from: jsonData) {
            return roots
        }

        let root = try decoder.decode(AccessibilityElement.self, from: jsonData)
        return [root]
    }

    /// Opens a session, performs one event and closes the session, on failure too.
    func perform(_ event: InputEvent, on id: DeviceID) async throws {
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
protocol RawVideoStreaming: DeviceBackend {
    func streamBGRA(
        from id: DeviceID,
        fps: Int,
        quality: Int,
        scale: Double,
        to fileDescriptor: Int32,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws
}
