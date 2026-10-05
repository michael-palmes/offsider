import Foundation
import OffsiderCore

/// Per-command state the backend's extensions share; the class itself keeps only `host`, `log` and the directory.
@MainActor
final class IOSDeviceState {
    var geometries: [String: IOSDeviceGeometry] = [:]
}

extension IOSDeviceBackend {
    public func screenshotPNG(for id: DeviceID) async throws -> Data {
        _ = try await requireBootedDevice(id)
        return try await host.timing.measure("capture") {
            try await IOSDeviceScreenshot.capture(udid: id.rawValue, directory: directory, root: host.privateRoot)
        }
    }

    public func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? {
        try await geometry(for: id).screenInfo
    }
}

extension IOSDeviceBackend {
    /// Read once per command from devicectl and written to `geometry.json`; the file serves when devicectl fails.
    public func geometry(for id: DeviceID) async throws -> IOSDeviceGeometry {
        let udid = id.rawValue
        if let known = state.geometries[udid] { return known }
        let folder = try IOSDevicePaths.device(udid, root: host.privateRoot)
        do {
            let output = try await directory.run(
                IOSDeviceGeometry.infoArguments.inserting(device: udid),
                label: "device info displays",
                udid: udid,
                timeout: IOSDeviceDirectory.infoTimeout
            )
            let geometry: IOSDeviceGeometry
            do {
                geometry = try IOSDeviceGeometry.parse(Data(output.utf8))
            } catch let error as IOSDeviceGeometry.ParseError {
                throw IOSDeviceError.devicectlFailed("device info displays", udid: udid, detail: error.detail)
            }
            state.geometries[udid] = geometry
            if let data = try? JSONEncoder().encode(geometry) {
                try? OffsiderPrivateDirectory.writeAtomically(data, named: IOSDeviceGeometry.fileName, in: folder)
            }
            return geometry
        } catch {
            guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: IOSDeviceGeometry.fileName, in: folder, maxBytes: 4096),
                  let cached = try? JSONDecoder().decode(IOSDeviceGeometry.self, from: data) else {
                throw error
            }
            log(.debug, "Using the cached display geometry for \(udid): \(error.localizedDescription)")
            state.geometries[udid] = cached
            return cached
        }
    }
}
