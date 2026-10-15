import Foundation

/// One app `devicectl device info apps` lists.
public struct DevicectlApp: Equatable, Sendable {
    public let bundleIdentifier: String
    public let name: String?

    public init(bundleIdentifier: String, name: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// `xcrun devicectl device info apps --json-output -`: the apps a person installed, without Apple's own, hidden or system apps.
public enum DevicectlAppList {
    public static func parse(_ data: Data) throws -> [DevicectlApp] {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let root = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any] else {
            throw DevicectlDeviceList.ParseError(detail: "the devicectl reply is not valid JSON")
        }
        if let outcome = (root["info"] as? [String: Any])?["outcome"] as? String, outcome != "success" {
            throw DevicectlDeviceList.ParseError(detail: "devicectl reported \(outcome)")
        }
        guard let rows = (root["result"] as? [String: Any])?["apps"] as? [[String: Any]] else {
            throw DevicectlDeviceList.ParseError(detail: "no result.apps in the devicectl reply")
        }
        return rows.compactMap { row in
            guard let id = row["bundleIdentifier"] as? String, !id.isEmpty, !id.hasPrefix("com.apple."),
                  row["appClearable"] as? Bool != false, row["hidden"] as? Bool != true else { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return DevicectlApp(bundleIdentifier: id, name: name)
        }
    }
}

extension IOSDeviceDirectory {
    /// The device's installed third-party apps; one `device info apps` query.
    public func installedApps(udid: String) async throws -> [DevicectlApp] {
        let output = try await run(
            ["device", "info", "apps", "--device", udid, "--timeout", "20", "--json-output", "-", "-q"],
            label: "device info apps", udid: udid, timeout: Self.infoTimeout
        )
        do {
            return try DevicectlAppList.parse(Data(output.utf8))
        } catch let error as DevicectlDeviceList.ParseError {
            throw IOSDeviceError.devicectlFailed("device info apps", udid: udid, detail: error.detail)
        }
    }
}
