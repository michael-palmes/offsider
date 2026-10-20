import Foundation

/// `devices status` text and JSON, version 1.
public enum DeviceAccessReport {
    public static func changeJSON(action: String, platform: DevicePlatform, key: String, allowance: DeviceAllowance?, stopped: [String] = []) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("action", .string(action)),
            ("platform", .string(platform.rawValue)),
            ("id", .string(key)),
            ("allowance", .optional(allowance) { entry in
                var fields: [(String, OrderedJSON)] = [
                    ("name", .string(entry.name)),
                    ("added", .string(ProcessStamp.timestamp(entry.added))),
                    ("expires", .optional(entry.expires) { .string(ProcessStamp.timestamp($0)) }),
                    ("apps", .array(entry.apps.map { .string($0) })),
                ]
                if let team = entry.team { fields.append(("team", .string(team))) }
                return .object(fields)
            }),
            ("stopped", .array(stopped.map { .string($0) })),
        ]).rendered(compact: true)
    }

    /// The `status` text: managed policy first, then one line per device.
    public static func statusText(_ policy: PhysicalDevicePolicy, now: Date, path: String) -> String {
        var lines: [String] = []
        let managed = policy.managed
        if managed.present {
            var parts: [String] = []
            if managed.unreadable { parts.append("unreadable, so every physical device is refused") }
            if let allow = managed.allowPhysicalDevices { parts.append(allow ? "physical devices on" : "physical devices off") }
            if let ids = managed.allowedDeviceIDs { parts.append("devices limited to \(ids.isEmpty ? "none" : ids.joined(separator: ", "))") }
            if let apps = managed.allowedBundleIDs { parts.append("apps limited to \(apps.isEmpty ? "none" : apps.joined(separator: ", "))") }
            lines.append("Managed policy: \(parts.joined(separator: "; ")).")
        } else {
            lines.append("Managed policy: none.")
        }
        if let problem = policy.listProblem {
            lines.append("The allow-list could not be read (\(problem)); no physical device is allowed.")
        } else if !policy.sealIntact {
            lines.append("The allow-list at \(path) was changed outside Offsider; no physical device is allowed until a person runs `offsider devices add` again.")
        }
        if policy.list.entries.isEmpty {
            lines.append("No physical device is allowed. A person allows one by running `offsider devices add` in their own terminal.")
        }
        for entry in policy.list.entries {
            let state: String
            switch policy.decision(platform: entry.platform, key: entry.key, now: now) {
            case .allowed: state = entry.expires.map { "allowed until \(ProcessStamp.timestamp($0))" } ?? "allowed until removed"
            case .refused(let refusal): state = "refused: \(refusal.explanation)"
            }
            let apps = entry.apps.isEmpty ? "" : entry.allowsWholeDevice && entry.pinnedApps.isEmpty ? ", any app and all logs" : ", apps \(entry.apps.joined(separator: ", "))"
            let team = entry.team.map { ", runner team \($0)" } ?? ""
            lines.append("\(entry.platform.rawValue)  \(entry.key)  \(entry.name): \(state)\(apps)\(team)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
