import Foundation

/// A device row from usbmuxd's `ListDevices`.
public struct UsbmuxDevice: Equatable, Sendable {
    public let deviceID: Int
    public let udid: String
    /// `USB` or `Network`; Offsider only ever connects `USB`.
    public let connectionType: String

    public init(deviceID: Int, udid: String, connectionType: String) {
        self.deviceID = deviceID
        self.udid = udid
        self.connectionType = connectionType
    }

    /// usbmuxd may list a modern UDID without its dash, so compare without dashes or case.
    public func matches(_ udid: String) -> Bool {
        Self.normalised(self.udid) == Self.normalised(udid)
    }

    static func normalised(_ udid: String) -> String {
        udid.replacingOccurrences(of: "-", with: "").uppercased()
    }
}

public enum UsbmuxRequest: Equatable, Sendable {
    case listDevices
    case connect(deviceID: Int, port: UInt16)

    public static let clientVersion = "offsider"
    public static let programName = "offsider"
    public static let bundleID = "com.mpalmes.offsider"
    public static let libUSBMuxVersion = 3

    /// `PortNumber` is the TCP port in network byte order, read back as a little-endian integer.
    public static func wirePort(_ port: UInt16) -> Int {
        Int(port.bigEndian)
    }

    public var dictionary: [String: Any] {
        var message: [String: Any] = [
            "ClientVersionString": Self.clientVersion,
            "ProgName": Self.programName,
            "BundleID": Self.bundleID,
            "kLibUSBMuxVersion": Self.libUSBMuxVersion,
        ]
        switch self {
        case .listDevices:
            message["MessageType"] = "ListDevices"
        case .connect(let deviceID, let port):
            message["MessageType"] = "Connect"
            message["DeviceID"] = deviceID
            message["PortNumber"] = Self.wirePort(port)
        }
        return message
    }

    public func payload() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
}

public enum UsbmuxReply {
    public static func dictionary(_ payload: Data) throws -> [String: Any] {
        guard let object = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil),
              let dictionary = object as? [String: Any] else {
            throw UsbmuxError.malformed("a reply that is not a plist dictionary")
        }
        return dictionary
    }

    public static func devices(_ payload: Data) throws -> [UsbmuxDevice] {
        guard let rows = try dictionary(payload)["DeviceList"] as? [[String: Any]] else {
            throw UsbmuxError.malformed("a ListDevices reply without DeviceList")
        }
        return rows.compactMap { row in
            let properties = row["Properties"] as? [String: Any] ?? [:]
            guard let deviceID = (row["DeviceID"] as? Int) ?? (properties["DeviceID"] as? Int),
                  let udid = (properties["SerialNumber"] as? String) ?? (properties["UDID"] as? String),
                  let connectionType = properties["ConnectionType"] as? String else { return nil }
            return UsbmuxDevice(deviceID: deviceID, udid: udid, connectionType: connectionType)
        }
    }

    /// The `Number` of a `Result` reply.
    public static func result(_ payload: Data) throws -> Int {
        let reply = try dictionary(payload)
        guard reply["MessageType"] as? String == "Result", let number = reply["Number"] as? Int else {
            throw UsbmuxError.malformed("a reply that is not a Result")
        }
        return number
    }
}
