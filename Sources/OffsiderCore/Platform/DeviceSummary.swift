import Foundation

/// What a `list-devices` row is: a simulator, a running emulator, a shut-down AVD or a physical phone.
public enum DeviceKind: String, Equatable, Sendable {
    case simulator
    case emulator
    case avd
    case physical
}

public struct DeviceSummary: Equatable, Sendable {
    public let id: String
    public let platform: DevicePlatform
    public let state: String
    public let name: String
    public let osVersion: String?
    public let deviceType: String?
    public let kind: DeviceKind
    /// `usb` for a phone, `network` for a refused Wi-Fi or TCP adb connection, else nil.
    public let connection: String?
    /// A running emulator's or shut-down AVD's name; nil for simulators and phones.
    public var avd: String?
    /// The running emulator's process; nil otherwise.
    public var bootedBy: ProcessStamp?

    public init(
        id: String,
        platform: DevicePlatform,
        state: String,
        name: String,
        osVersion: String?,
        deviceType: String?,
        kind: DeviceKind,
        connection: String? = nil,
        avd: String? = nil,
        bootedBy: ProcessStamp? = nil
    ) {
        self.id = id
        self.platform = platform
        self.state = state
        self.name = name
        self.osVersion = osVersion
        self.deviceType = deviceType
        self.kind = kind
        self.connection = connection
        self.avd = avd
        self.bootedBy = bootedBy
    }
}

public enum DeviceListRenderer {
    public static let jsonVersion = 1

    public static func table(_ devices: [DeviceSummary]) -> String {
        let header = ["PLATFORM", "STATE", "ID", "NAME", "OS"]
        let rows = [header] + devices.map { [$0.platform.rawValue, $0.state, $0.id, $0.name, $0.osVersion ?? "-"] }
        let widths = header.indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[column] - cell.count)
            }
            .joined(separator: "  ")
        }
        .joined(separator: "\n") + "\n"
    }

    /// Keys stay in schema order with explicit nulls, which `JSONEncoder` does not guarantee.
    public static func json(_ devices: [DeviceSummary]) -> String {
        guard !devices.isEmpty else {
            return "{\n  \"version\": \(jsonVersion),\n  \"devices\": []\n}\n"
        }
        let objects = devices.map { device in
            let fields = [
                ("id", string(device.id)),
                ("platform", string(device.platform.rawValue)),
                ("state", string(device.state)),
                ("name", string(device.name)),
                ("osVersion", device.osVersion.map(string) ?? "null"),
                ("deviceType", device.deviceType.map(string) ?? "null"),
                ("kind", string(device.kind.rawValue)),
                ("connection", device.connection.map(string) ?? "null"),
                ("avd", device.avd.map(string) ?? "null"),
                ("bootedBy", device.bootedBy.map(stamp) ?? "null"),
            ]
            let body = fields.map { "      \(string($0.0)): \($0.1)" }.joined(separator: ",\n")
            return "    {\n\(body)\n    }"
        }
        return "{\n  \"version\": \(jsonVersion),\n  \"devices\": [\n\(objects.joined(separator: ",\n"))\n  ]\n}\n"
    }

    static func stamp(_ stamp: ProcessStamp) -> String {
        let startedAt: String = string(ProcessStamp.timestamp(stamp.startedAt))
        return "{\"pid\": \(stamp.pid), \"startedAt\": \(startedAt)}"
    }

    private static func string(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
