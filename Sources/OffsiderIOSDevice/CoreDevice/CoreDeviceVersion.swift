import Foundation
import XPC

/// The installed CoreDevice package's version, which `createservicesocket` requests carry and HID input is gated on.
public struct CoreDeviceVersion: Comparable, CustomStringConvertible, Sendable {
    public static let frameworkPath = "/Library/Developer/PrivateFrameworks/CoreDevice.framework"
    /// The first CoreDevice whose disk image carries the device's HID daemon (Xcode 27).
    public static let hidFloor = CoreDeviceVersion(components: [636])

    public let components: [Int]

    public init(components: [Int]) {
        self.components = components
    }

    /// `651.13.4`; nil unless every dot-separated part is a number.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public var supportsHID: Bool { self >= Self.hidFloor }

    /// Missing trailing parts count as zero, so 636 equals 636.0.
    public static func < (lhs: CoreDeviceVersion, rhs: CoreDeviceVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        let left = lhs.components + Array(repeating: 0, count: count - lhs.components.count)
        let right = rhs.components + Array(repeating: 0, count: count - rhs.components.count)
        return left.lexicographicallyPrecedes(right)
    }

    public static func == (lhs: CoreDeviceVersion, rhs: CoreDeviceVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// The framework's `CFBundleVersion`; nil when CoreDevice is not installed.
    public static func installed(frameworkPath: String = frameworkPath) -> CoreDeviceVersion? {
        let plist = NSDictionary(contentsOfFile: frameworkPath + "/Resources/Info.plist")
        return (plist?["CFBundleVersion"] as? String).flatMap(CoreDeviceVersion.init)
    }

    /// The `CoreDevice.coreDeviceVersion` dictionary CoreDeviceService expects from its clients.
    var xpcObject: xpc_object_t {
        let version = xpc_dictionary_create(nil, nil, 0)
        let array = xpc_array_create(nil, 0)
        for component in components {
            xpc_array_append_value(array, xpc_uint64_create(UInt64(max(component, 0))))
        }
        xpc_dictionary_set_value(version, "components", array)
        xpc_dictionary_set_int64(version, "originalComponentsCount", Int64(components.count))
        xpc_dictionary_set_string(version, "stringValue", description)
        return version
    }
}
