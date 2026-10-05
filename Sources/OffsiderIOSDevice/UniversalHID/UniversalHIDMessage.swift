import Foundation

/// The plain dictionaries `dtuhidd`'s UniversalHID service decodes: `Request` with one case of its payload enum.
public enum UniversalHIDMessage {
    public static let feature = "com.apple.coredevice.feature.remote.universalhidservice"

    /// The high bit-32 marks a host-registered surface, as Universal Control numbers its mirrored keyboards.
    public static let virtualKeyboardServiceID: UInt64 = 0x1_0000_2001

    static func request(_ payload: [String: UniversalHIDValue]) -> UniversalHIDValue {
        .dictionary([
            "featureIdentifier": .string(feature),
            "messageType": .string("Request"),
            "payload": .dictionary(payload),
        ])
    }

    /// Asks for every registered surface; the reply lists each with its service ID.
    public static func connectedServices() -> UniversalHIDValue {
        request(["connectedServices": .dictionary([:])])
    }

    /// One raw report to one surface.
    public static func send(_ report: Data, to serviceID: UInt64) -> UniversalHIDValue {
        request(["send": .dictionary(["_0": .data(report), "_1": .uint(serviceID)])])
    }

    /// Registers a host keyboard surface; leaf values in the property storage are Codable type envelopes.
    public static func createKeyboardService(id serviceID: UInt64 = virtualKeyboardServiceID, product: String = "Offsider keyboard") -> UniversalHIDValue {
        let page: Int64 = 1
        let usage: Int64 = 6
        let vendor: Int64 = 0x05AC
        let productID: Int64 = 0x0250
        let storage: [String: UniversalHIDValue] = [
            "Manufacturer": .dictionary(["string": .string("Offsider")]),
            "Product": .dictionary(["string": .string(product)]),
            "ProductID": .dictionary(["int": .int(productID)]),
            "VendorID": .dictionary(["int": .int(vendor)]),
            "PrimaryUsage": .dictionary(["int": .int(usage)]),
            "PrimaryUsagePage": .dictionary(["int": .int(page)]),
            "DeviceUsagePairs": .dictionary(["array": .array([
                .dictionary(["dictionary": .dictionary([
                    "DeviceUsage": .dictionary(["int": .int(usage)]),
                    "DeviceUsagePage": .dictionary(["int": .int(page)]),
                ])]),
            ])]),
            "Transport": .dictionary(["string": .string("USB")]),
            "ReportDescriptor": .dictionary(["data": .data(keyboardDescriptor)]),
            "UniversalControlVirtualService": .dictionary(["bool": .bool(true)]),
            "_ServiceID": .dictionary(["uint": .uint(serviceID)]),
        ]
        return request(["createService": .dictionary(["_0": .dictionary([
            "DeviceUsagePairs": .array([.dictionary(["DeviceUsage": .int(usage), "DeviceUsagePage": .int(page)])]),
            "PrimaryUsage": .uint(UInt64(usage)),
            "PrimaryUsagePage": .uint(UInt64(page)),
            "Product": .string(product),
            "ProductID": .int(productID),
            "VendorID": .int(vendor),
            "_CoreDevice_codablePropertyStorage": .dictionary(storage),
            "_ServiceID": .uint(serviceID),
        ])])])
    }

    /// A boot-protocol keyboard descriptor; it only has to mark the surface as a keyboard.
    static let keyboardDescriptor = Data([
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x95, 0x08, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x05, 0x07, 0x19, 0x00, 0x29, 0xFF, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x95, 0x06, 0x75, 0x08, 0x81, 0x00,
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0xC0,
    ])
}
