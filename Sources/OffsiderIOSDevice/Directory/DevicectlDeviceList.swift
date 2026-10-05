import Foundation

/// One physical iPhone or iPad as `devicectl` lists it; every field but the UDID may be missing on some Xcode.
public struct DevicectlDevice: Equatable, Sendable {
    public var udid: String
    public var coreDeviceIdentifier: String?
    public var marketingName: String?
    public var productType: String?
    public var osVersion: String?
    public var osBuild: String?
    public var pairingState: String?
    /// `wired`, `localNetwork`; nil when the device is not connected.
    public var transportType: String?
    /// `properties.connection.state` (`connected`, `disconnected`, `unavailable`), else the old `tunnelState`.
    public var connectionState: String?
    public var tunnelState: String?
    public var developerModeStatus: String?
    public var ddiServicesAvailable: Bool?

    public init(
        udid: String,
        coreDeviceIdentifier: String? = nil,
        marketingName: String? = nil,
        productType: String? = nil,
        osVersion: String? = nil,
        osBuild: String? = nil,
        pairingState: String? = nil,
        transportType: String? = nil,
        connectionState: String? = nil,
        tunnelState: String? = nil,
        developerModeStatus: String? = nil,
        ddiServicesAvailable: Bool? = nil
    ) {
        self.udid = udid
        self.coreDeviceIdentifier = coreDeviceIdentifier
        self.marketingName = marketingName
        self.productType = productType
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.pairingState = pairingState
        self.transportType = transportType
        self.connectionState = connectionState
        self.tunnelState = tunnelState
        self.developerModeStatus = developerModeStatus
        self.ddiServicesAvailable = ddiServicesAvailable
    }

    /// `Apple iPhone 15 Pro Max`, never the owner's device name.
    public var label: String {
        "Apple \(marketingName ?? productType ?? "iPhone or iPad")"
    }
}

/// `xcrun devicectl list devices --json-output -`: the CoreDevice version and the physical iOS and iPadOS rows.
public struct DevicectlDeviceList: Equatable, Sendable {
    public var coreDeviceVersion: String?
    public var devices: [DevicectlDevice]

    public init(coreDeviceVersion: String?, devices: [DevicectlDevice]) {
        self.coreDeviceVersion = coreDeviceVersion
        self.devices = devices
    }

    public struct ParseError: Error, Equatable, Sendable {
        public let detail: String
    }

    static let iosPlatforms: Set<String> = ["iOS", "iPadOS"]

    /// Reads `properties.*` first and the deprecated blocks as fallback; drops simulators, watches and Macs.
    public static func parse(_ data: Data) throws -> DevicectlDeviceList {
        let root = try object(data)
        let info = root["info"] as? [String: Any]
        if let outcome = info?["outcome"] as? String, outcome != "success" {
            throw ParseError(detail: "devicectl reported \(outcome)")
        }
        guard let result = root["result"] as? [String: Any], let rows = result["devices"] as? [[String: Any]] else {
            throw ParseError(detail: "no result.devices in the devicectl reply")
        }
        return DevicectlDeviceList(coreDeviceVersion: info?["version"] as? String, devices: rows.compactMap(device))
    }

    /// `devicectl device info details`: one row in the listing's shape.
    public static func parseDetails(_ data: Data) throws -> DevicectlDevice? {
        let root = try object(data)
        guard let result = root["result"] as? [String: Any] else {
            throw ParseError(detail: "no result in the devicectl reply")
        }
        return device(result)
    }

    static func device(_ row: [String: Any]) -> DevicectlDevice? {
        let properties = row["properties"] as? [String: Any] ?? [:]
        let connection = properties["connection"] as? [String: Any] ?? [:]
        let hardware = properties["hardware"] as? [String: Any] ?? [:]
        let software = properties["software"] as? [String: Any] ?? [:]
        let state = properties["state"] as? [String: Any] ?? [:]
        let oldHardware = row["hardwareProperties"] as? [String: Any] ?? [:]
        let oldDevice = row["deviceProperties"] as? [String: Any] ?? [:]
        let oldConnection = row["connectionProperties"] as? [String: Any] ?? [:]

        func string(_ key: String, _ new: [String: Any], _ old: [String: Any]) -> String? {
            (new[key] as? String) ?? (old[key] as? String)
        }

        guard let platform = string("platform", hardware, oldHardware), iosPlatforms.contains(platform),
              string("reality", hardware, oldHardware) != "simulated",
              let udid = string("udid", hardware, oldHardware) else { return nil }

        let osVersion = ((software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String) ?? (oldDevice["osVersionNumber"] as? String)
        let buildVersions = software["osBuildVersions"] as? [String: Any]
        let osBuild = ((buildVersions?["buildVersion"] as? [String: Any])?["name"] as? String) ?? (oldDevice["osBuildUpdate"] as? String)
        let tunnelState = oldConnection["tunnelState"] as? String
        return DevicectlDevice(
            udid: udid,
            coreDeviceIdentifier: row["identifier"] as? String,
            marketingName: string("marketingName", hardware, oldHardware),
            productType: string("productType", hardware, oldHardware),
            osVersion: osVersion,
            osBuild: osBuild,
            pairingState: string("pairingState", connection, oldConnection),
            transportType: string("transportType", connection, oldConnection),
            connectionState: (connection["state"] as? String) ?? tunnelState,
            tunnelState: tunnelState,
            developerModeStatus: developerMode(state["developerModeStatus"]) ?? (oldDevice["developerModeStatus"] as? String),
            ddiServicesAvailable: oldDevice["ddiServicesAvailable"] as? Bool
        )
    }

    /// The newer shape is `{"enabled": {"mode": 1}}`: the one key is the status.
    private static func developerMode(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let object = value as? [String: Any], object.count == 1 else { return nil }
        return object.keys.first
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else {
            throw ParseError(detail: "devicectl printed no JSON")
        }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data[start...]) as? [String: Any] else {
                throw ParseError(detail: "the devicectl reply is not a JSON object")
            }
            return root
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError(detail: "the devicectl reply is not valid JSON")
        }
    }
}

/// `devicectl device info lockState` and the backlight from `info displays`.
public enum DevicectlLockInfo {
    public static func passcodeRequired(_ data: Data) -> Bool? {
        result(data)?["passcodeRequired"] as? Bool
    }

    /// True when the screen is on; nil when the reply has no backlight state.
    public static func backlightOn(_ data: Data) -> Bool? {
        guard let state = result(data)?["backlightState"] as? String else { return nil }
        return state != "off"
    }

    private static func result(_ data: Data) -> [String: Any]? {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let root = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any] else { return nil }
        return root["result"] as? [String: Any]
    }
}
