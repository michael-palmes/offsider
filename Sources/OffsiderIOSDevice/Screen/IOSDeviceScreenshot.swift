import Foundation
import OffsiderCore

/// `devicectl device capture screenshot` into the device's private `captures/` directory, read back and removed.
enum IOSDeviceScreenshot {
    static let directoryName = "captures"
    static let timeout: TimeInterval = 25
    static let maximumBytes = 64 * 1024 * 1024

    static func arguments(udid: String, destination: String) -> [String] {
        ["device", "capture", "screenshot", "--device", udid, "--destination", destination, "--timeout", "15", "-q"]
    }

    @MainActor
    static func capture(udid: String, directory: IOSDeviceDirectory, root: String) async throws -> Data {
        let captures = try IOSDevicePaths.subdirectory(directoryName, of: udid, root: root)
        let destination = (captures as NSString).appendingPathComponent("\(UUID().uuidString).png")
        defer { unlink(destination) }
        _ = try await directory.run(arguments(udid: udid, destination: destination), label: "device capture screenshot", udid: udid, timeout: timeout)
        guard let data = FileManager.default.contents(atPath: destination), !data.isEmpty else {
            throw IOSDeviceError.devicectlFailed("device capture screenshot", udid: udid, detail: "it wrote no image")
        }
        guard data.count <= maximumBytes, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw IOSDeviceError.devicectlFailed("device capture screenshot", udid: udid, detail: "it wrote something other than a PNG")
        }
        return data
    }
}
