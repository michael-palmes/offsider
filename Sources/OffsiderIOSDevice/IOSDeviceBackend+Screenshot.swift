import Foundation
import OffsiderCore

/// Per-command state the backend's extensions share; the class itself keeps only `host`, `log` and the directory.
@MainActor
final class IOSDeviceState {
    var geometries: [String: IOSDeviceGeometry] = [:]
    var targetApp: String?
    var runners: [String: RunnerClient] = [:]
    var connector: (any RunnerConnecting)?
    var sessions: [String: DeviceSessionClient] = [:]
    var sessionFailures: [String: Error] = [:]
    var sessionConnector: (any DeviceSessionConnecting)?
    var streamNoticeShown = false
    var captureSources: [String: String] = [:]
    var pinPolicy: (@MainActor (String) -> String?)?
    var pinConfirmed: [String: Date] = [:]
    /// Devices sent input since their pinned app was last confirmed in front; their next check is timed as `foreground-recheck`.
    var inputSincePinCheck: Set<String> = []
    var runnerTeam: String?
}

extension IOSDeviceBackend {
    /// The broker's latest frame on an Xcode 27 host; `devicectl device capture screenshot` when its stream cannot serve one.
    public func screenshotPNG(for id: DeviceID) async throws -> Data {
        _ = try await requireBootedDevice(id)
        // Video asks for a frame many times a second, so the check is repeated at most every two seconds; any input clears it.
        try await requirePinnedAppInFront(id, maxAge: 2)
        if hostHasHID, sessionsAvailable {
            do {
                let png = try await host.timing.measure("stream-capture") {
                    try await session(for: id).frame(.png).data
                }
                state.captureSources[id.rawValue] = Self.streamCapture
                return png
            } catch {
                if !state.streamNoticeShown {
                    state.streamNoticeShown = true
                    log(.notice, "The screen stream is unavailable (\((error as? IOSDeviceError)?.message ?? error.localizedDescription)); capturing with devicectl instead, which is slower and draws a staged status bar (9:41, full signal).")
                }
            }
        }
        let png = try await host.timing.measure("capture") {
            try await IOSDeviceScreenshot.capture(udid: id.rawValue, directory: directory, root: host.privateRoot)
        }
        state.captureSources[id.rawValue] = Self.devicectlCapture
        return png
    }

    public static let streamCapture = "stream"
    public static let devicectlCapture = "devicectl"

    public func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? {
        try await geometry(for: id).screenInfo
    }
}

extension IOSDeviceBackend: CaptureSourceReporting {
    public func captureSource(for id: DeviceID) -> String? {
        state.captureSources[id.rawValue]
    }
}

extension IOSDeviceBackend {
    /// Read once per command from devicectl and written to `geometry.json`; the file serves when devicectl fails.
    public func geometry(for id: DeviceID) async throws -> IOSDeviceGeometry {
        let udid = id.rawValue
        if let known = state.geometries[udid] { return known }
        if let live = await liveSession(for: id)?.status?.geometry {
            state.geometries[udid] = live
            return live
        }
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
