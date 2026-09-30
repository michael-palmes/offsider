import Foundation

struct EmulatorStatusSummary: Equatable, Sendable {
    let version: String
    let booted: Bool
    let uptimeMilliseconds: UInt64
}

/// One `sendKey`: a USB `page << 16 | usage` code, a W3C key value such as `GoHome`, or printable text.
enum EmulatorKeyEvent: Equatable, Sendable {
    case usb(UInt32, KeyPhase)
    case w3c(String, KeyPhase)
    case text(String)
}

/// A finger in the panel's natural portrait pixels, which `sendTouch` takes whatever the guest's rotation.
struct PanelTouch: Equatable, Sendable {
    var x: Int32
    var y: Int32
    /// Zero lifts the finger.
    var pressure: Int32
    var identifier: Int32 = 0
}

enum EmulatorImageFormat: Equatable, Sendable {
    case png
    case rgba8888
}

/// The emulator fits the image inside the box keeping its aspect ratio; it needs both sides to scale at all.
struct FrameBox: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// One screenshot as the emulator sent it: turned for the emulator's rotation, not necessarily the guest's.
struct EmulatorFrame: Equatable, Sendable {
    let format: EmulatorImageFormat
    let width: Int
    let height: Int
    /// `Image.format.rotation`, 0 to 3.
    let emulatorRotation: Int
    let sequence: UInt32
    let bytes: Data
}

/// What Android commands need from the emulator's gRPC endpoint; a protocol so tests never reach a real one.
protocol EmulatorControlling: AnyObject, Sendable {
    var endpoint: String { get }
    func status() async throws -> EmulatorStatusSummary
    func sendTouch(_ touch: PanelTouch) async throws
    func sendKey(_ event: EmulatorKeyEvent) async throws
    func screenshot(_ format: EmulatorImageFormat, fitting box: FrameBox?) async throws -> EmulatorFrame
    func screenshotStream(_ format: EmulatorImageFormat, fitting box: FrameBox?) -> AsyncThrowingStream<EmulatorFrame, any Error>
    func clipboard() async throws -> String
    func setClipboard(_ text: String) async throws
    /// Shuts the connection down and removes a registered signing key.
    func close() async
}

/// Opens a client and proves it with `getStatus`, or throws the mapped reason it could not.
protocol EmulatorConnecting: Sendable {
    func connect(discovery: EmulatorDiscovery, auth: EmulatorAuth) async throws -> any EmulatorControlling
}
