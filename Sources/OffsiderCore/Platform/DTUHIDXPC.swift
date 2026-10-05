import Foundation
import XPC

extension DTUHIDValue {
    /// The XPC object of the wire type `dtuhidd` decodes, for simulators and devices alike.
    public var xpcObject: xpc_object_t {
        switch self {
        case let .string(text): return xpc_string_create(text)
        case let .bool(flag): return xpc_bool_create(flag)
        case let .uint(number): return xpc_uint64_create(number)
        case let .double(number): return xpc_double_create(number)
        case let .data(bytes): return bytes.withUnsafeBytes { xpc_data_create($0.baseAddress, bytes.count) }
        case let .dictionary(entries):
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            for (key, entry) in entries {
                xpc_dictionary_set_value(dictionary, key, entry.xpcObject)
            }
            return dictionary
        }
    }
}
