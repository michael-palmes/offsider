import Foundation

/// The built-in displays a simulator device type declares in its profile's `capabilities.plist`.
public enum SimulatorDisplayProfile {
    /// From the plist file's data; nil when it is not a property list or declares no integrated display.
    public static func displays(plist data: Data) -> [DisplayDescriptor]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return displays(capabilities: root)
    }

    /// From the plist's root or its `capabilities` dictionary, keeping `displayType == "integrated"` entries in screen ID order.
    public static func displays(capabilities: [String: Any]) -> [DisplayDescriptor]? {
        let inner = capabilities["capabilities"] as? [String: Any] ?? capabilities
        guard let entries = inner["displays"] as? [[String: Any]] else { return nil }
        let integrated = entries.compactMap(descriptor).sorted { (Int($0.platformId) ?? 0) < (Int($1.platformId) ?? 0) }
        return integrated.isEmpty ? nil : DisplayDescriptor.assigningRoles(integrated)
    }

    private static func descriptor(_ entry: [String: Any]) -> DisplayDescriptor? {
        guard entry["displayType"] as? String == "integrated",
              let screenID = integer(entry["screenID"]),
              let width = integer(entry["width"]), let height = integer(entry["height"]), width > 0, height > 0 else {
            return nil
        }
        let scale = (entry["scale"] as? NSNumber)?.doubleValue ?? 1
        return DisplayDescriptor(
            role: .main,
            platformId: String(screenID),
            name: entry["displayName"] as? String ?? entry["deviceName"] as? String ?? "Display \(screenID)",
            pixelWidth: width,
            pixelHeight: height,
            scale: scale > 0 ? scale : 1,
            nativeOrientation: integer(entry["nativeOrientation"]) ?? 0
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
