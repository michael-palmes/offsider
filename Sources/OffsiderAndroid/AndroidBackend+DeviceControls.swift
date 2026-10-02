import Foundation
import OffsiderCore

/// Shell commands and parsers for appearance, font scale and rotation.
enum AndroidDeviceSettings {
    static let readNightMode = "cmd uimode night"
    static let readFontScale = "settings get system font_scale"

    static func setNightMode(_ appearance: Appearance) -> String {
        "cmd uimode night \(appearance == .dark ? "yes" : "no")"
    }

    static func setFontScale(_ scale: Double) -> String {
        "settings put system font_scale \(DeviceSettingsReport.number(scale))"
    }

    /// Auto-rotate goes off first, or the sensor turns the display straight back; it stays off afterwards.
    static func setRotation(_ orientation: DeviceOrientation) -> String {
        "settings put system accelerometer_rotation 0; settings put system user_rotation \(orientation.androidRotation)"
    }

    /// `Night mode: yes`; `auto` and `custom` follow a schedule; nil for anything unexpected.
    static func parseNightMode(_ output: String) -> AppearanceReading? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("Night mode:") }) else { return nil }
        let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "yes": return .fixed(.dark)
        case "no": return .fixed(.light)
        case "auto": return .scheduled("auto")
        case let mode? where mode.hasPrefix("custom"): return .scheduled("custom")
        default: return nil
        }
    }

    /// `null` (never set) is the default 1.0.
    static func parseFontScale(_ output: String) -> Double? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return 1.0 }
        guard let scale = Double(trimmed), scale > 0 else { return nil }
        return scale
    }
}

extension AndroidBackend: DeviceSettingsControlling {
    public func appearance(on id: DeviceID) async throws -> AppearanceReading {
        let output = try await settingsShell(AndroidDeviceSettings.readNightMode, on: id.rawValue)
        guard let appearance = AndroidDeviceSettings.parseNightMode(output) else {
            let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
            throw AndroidError.adbCommandFailed(
                serial: id.rawValue,
                command: AndroidDeviceSettings.readNightMode,
                detail: "expected Night mode yes, no, auto or custom but got \(firstLine)"
            )
        }
        return appearance
    }

    public func setAppearance(_ appearance: Appearance, on id: DeviceID) async throws {
        _ = try await settingsShell(AndroidDeviceSettings.setNightMode(appearance), on: id.rawValue)
    }

    public func contentSize(on id: DeviceID) async throws -> ContentSizeReading {
        let output = try await settingsShell(AndroidDeviceSettings.readFontScale, on: id.rawValue)
        guard let scale = AndroidDeviceSettings.parseFontScale(output) else {
            throw AndroidError.adbCommandFailed(
                serial: id.rawValue,
                command: AndroidDeviceSettings.readFontScale,
                detail: "expected a number, got \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return ContentSizeReading(category: .nearest(androidFontScale: scale), fontScale: scale)
    }

    public func setContentSize(_ category: ContentSizeCategory, on id: DeviceID) async throws {
        _ = try await settingsShell(AndroidDeviceSettings.setFontScale(category.androidFontScale), on: id.rawValue)
    }

    /// Stdout of a settings command; a non-zero exit is an error quoting stderr.
    private func settingsShell(_ command: String, on serial: String) async throws -> String {
        try await prepare()
        let result = try await requireClient().shell(command, on: serial, label: command)
        guard result.status == 0 else {
            let detail = (result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(result.status)"
            throw AndroidError.adbCommandFailed(serial: serial, command: command, detail: detail)
        }
        return result.stdoutText
    }
}

extension AndroidBackend: OrientationControlling {
    /// Probes the display again each time, so a poll sees the turn.
    public func orientation(of id: DeviceID) async throws -> DeviceOrientation? {
        geometries[id.rawValue] = nil
        return DeviceOrientation(androidRotation: try await geometry(for: id.rawValue).rotation)
    }

    public func requestOrientation(_ orientation: DeviceOrientation, on id: DeviceID) async throws {
        _ = try await settingsShell(AndroidDeviceSettings.setRotation(orientation), on: id.rawValue)
        geometries[id.rawValue] = nil
    }
}
