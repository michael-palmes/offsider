import Foundation
import OffsiderCore

extension IOSDeviceBackend: DeviceSettingsControlling {
    public func appearance(on id: DeviceID) async throws -> AppearanceReading {
        .fixed(try await readAppearance(id).appearance)
    }

    public func setAppearance(_ appearance: Appearance, on id: DeviceID) async throws {
        _ = try await directory.run(
            IOSDeviceSettings.setAppearance(appearance, udid: id.rawValue),
            label: "device settings appearance",
            udid: id.rawValue,
            timeout: IOSDeviceDirectory.infoTimeout
        )
    }

    public func contentSize(on id: DeviceID) async throws -> ContentSizeReading {
        ContentSizeReading(category: try await readAppearance(id).contentSize, fontScale: nil)
    }

    public func setContentSize(_ category: ContentSizeCategory, on id: DeviceID) async throws {
        _ = try await directory.run(
            IOSDeviceSettings.setContentSize(category, udid: id.rawValue),
            label: "device settings appearance",
            udid: id.rawValue,
            timeout: IOSDeviceDirectory.infoTimeout
        )
    }

    /// One `devicectl device info appearance` answers both the style and the text size.
    func readAppearance(_ id: DeviceID) async throws -> IOSDeviceAppearance {
        let output = try await directory.run(
            IOSDeviceSettings.readAppearance(udid: id.rawValue),
            label: "device info appearance",
            udid: id.rawValue,
            timeout: IOSDeviceDirectory.infoTimeout
        )
        do {
            return try IOSDeviceSettings.parseAppearance(Data(output.utf8))
        } catch let error as IOSDeviceSettings.ParseError {
            throw IOSDeviceError.devicectlFailed("device info appearance", udid: id.rawValue, detail: error.detail)
        }
    }
}

extension IOSDeviceBackend: OrientationControlling {
    /// Reads the displays again each time, so a poll sees the turn, and refreshes the panel input uses.
    public func orientation(of id: DeviceID) async throws -> DeviceOrientation? {
        let output = try await directory.run(
            IOSDeviceSettings.readDisplays(udid: id.rawValue),
            label: "device info displays",
            udid: id.rawValue,
            timeout: IOSDeviceDirectory.infoTimeout
        )
        let data = Data(output.utf8)
        input.panels[id.rawValue] = IOSDevicePanel.parse(displaysJSON: data)
        return IOSDeviceSettings.parseOrientation(displaysJSON: data)
    }

    public func requestOrientation(_ orientation: DeviceOrientation, on id: DeviceID) async throws {
        input.panels[id.rawValue] = nil
        _ = try await directory.run(
            IOSDeviceSettings.setOrientation(orientation, udid: id.rawValue),
            label: "device orientation set",
            udid: id.rawValue,
            timeout: IOSDeviceDirectory.infoTimeout
        )
    }
}
