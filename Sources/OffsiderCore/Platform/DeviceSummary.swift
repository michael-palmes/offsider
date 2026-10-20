import Foundation

/// What a `devices` row is: a simulator, a running emulator, a shut-down AVD or a physical phone.
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
    /// The Offsider command holding the device's lock right now.
    public var heldBy: DeviceLockHolder?
    /// The advisory lease on the device, from `offsider lease set`.
    public var lease: DeviceLease?
    /// True when `lease` is this session's, as `doctor`'s `device.lease` decides.
    public var leaseIsMine = false
    /// For a physical row, whether the allow-list and managed policy let Offsider drive it; nil for simulators and emulators.
    public var allowed: Bool?

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

    /// The most characters a device name, state or OS shows in the table.
    public static let maxNameCharacters = 80

    /// Names come from the device, so they are escaped, and quoted for an agent.
    public static func table(_ devices: [DeviceSummary], profile: OutputProfile = .current) -> String {
        AgentRenderer.table(DevicesScreen.table(devices), profile: profile)
    }

    /// Keys stay in schema order with explicit nulls, which `JSONEncoder` does not guarantee: one line for an agent, indented for a person.
    /// `hiddenPhysical` counts the physical rows left out because they are not allowed.
    public static func json(_ devices: [DeviceSummary], hiddenPhysical: Int = 0, compact: Bool = false) -> String {
        var members: [(String, OrderedJSON)] = [
            ("version", .integer(jsonVersion)),
            ("devices", .array(devices.map(object))),
            ("hiddenPhysical", .integer(hiddenPhysical)),
        ]
        if !devices.isEmpty {
            // The values each device reports about itself.
            let paths = ["devices[].name"]
                + (devices.contains { $0.osVersion != nil } ? ["devices[].osVersion"] : [])
                + (devices.contains { $0.deviceType != nil } ? ["devices[].deviceType"] : [])
            members.append((UntrustedPaths.key, .array(paths.map(OrderedJSON.string))))
        }
        return OrderedJSON.object(members).rendered(compact: compact) + "\n"
    }

    static func object(_ device: DeviceSummary) -> OrderedJSON {
        .object([
            ("id", .string(device.id)),
            ("platform", .string(device.platform.rawValue)),
            ("state", .string(device.state)),
            ("name", .string(device.name)),
            ("osVersion", .optional(device.osVersion, OrderedJSON.string)),
            ("deviceType", .optional(device.deviceType, OrderedJSON.string)),
            ("kind", .string(device.kind.rawValue)),
            ("connection", .optional(device.connection, OrderedJSON.string)),
            ("avd", .optional(device.avd, OrderedJSON.string)),
            ("bootedBy", .optional(device.bootedBy) { .object([("pid", .integer(Int($0.pid))), ("startedAt", .string(ProcessStamp.timestamp($0.startedAt)))]) }),
            ("heldBy", .optional(device.heldBy) { holder in
                .object([
                    ("pid", .integer(Int(holder.pid))), ("command", .string(holder.command)),
                    ("startedAt", .optional(holder.startedAt) { .string(ProcessStamp.timestamp($0)) }),
                ])
            }),
            ("lease", .optional(device.lease) { lease in
                .object([
                    ("label", .string(lease.label)), ("since", .string(ProcessStamp.timestamp(lease.created))),
                    ("expiresAt", .string(ProcessStamp.timestamp(lease.expires))), ("mine", .bool(device.leaseIsMine)),
                ])
            }),
            ("allowed", .optional(device.allowed, OrderedJSON.bool)),
        ])
    }
}
