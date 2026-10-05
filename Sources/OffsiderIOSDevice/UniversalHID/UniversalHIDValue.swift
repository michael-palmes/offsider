import Foundation
import XPC

/// A value in a UniversalHID request or reply, kept apart from XPC so the shapes can be tested.
public indirect enum UniversalHIDValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case data(Data)
    case array([UniversalHIDValue])
    case dictionary([String: UniversalHIDValue])
    /// An XPC type the protocol does not use, such as a null or a file descriptor.
    case other(String)

    public subscript(key: String) -> UniversalHIDValue? {
        guard case let .dictionary(entries) = self else { return nil }
        return entries[key]
    }

    /// Either integer type as an unsigned value; nil for anything else or a negative int.
    public var unsigned: UInt64? {
        switch self {
        case let .uint(number): return number
        case let .int(number) where number >= 0: return UInt64(number)
        default: return nil
        }
    }

    public var text: String? {
        guard case let .string(text) = self else { return nil }
        return text
    }

    var xpcObject: xpc_object_t {
        switch self {
        case let .string(text): return xpc_string_create(text)
        case let .bool(flag): return xpc_bool_create(flag)
        case let .int(number): return xpc_int64_create(number)
        case let .uint(number): return xpc_uint64_create(number)
        case let .double(number): return xpc_double_create(number)
        case let .data(bytes): return bytes.withUnsafeBytes { xpc_data_create($0.baseAddress, bytes.count) }
        case let .array(items):
            let array = xpc_array_create(nil, 0)
            for item in items { xpc_array_append_value(array, item.xpcObject) }
            return array
        case let .dictionary(entries):
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            for (key, entry) in entries { xpc_dictionary_set_value(dictionary, key, entry.xpcObject) }
            return dictionary
        case .other: return xpc_null_create()
        }
    }

    init(xpc object: xpc_object_t) {
        let type = xpc_get_type(object)
        switch type {
        case XPC_TYPE_STRING: self = .string(xpc_string_get_string_ptr(object).map { String(cString: $0) } ?? "")
        case XPC_TYPE_BOOL: self = .bool(xpc_bool_get_value(object))
        case XPC_TYPE_INT64: self = .int(xpc_int64_get_value(object))
        case XPC_TYPE_UINT64: self = .uint(xpc_uint64_get_value(object))
        case XPC_TYPE_DOUBLE: self = .double(xpc_double_get_value(object))
        case XPC_TYPE_DATA:
            let length = xpc_data_get_length(object)
            self = .data(xpc_data_get_bytes_ptr(object).map { Data(bytes: $0, count: length) } ?? Data())
        case XPC_TYPE_ARRAY:
            var items: [UniversalHIDValue] = []
            xpc_array_apply(object) { _, item in
                items.append(UniversalHIDValue(xpc: item))
                return true
            }
            self = .array(items)
        case XPC_TYPE_DICTIONARY:
            var entries: [String: UniversalHIDValue] = [:]
            xpc_dictionary_apply(object) { key, item in
                entries[String(cString: key)] = UniversalHIDValue(xpc: item)
                return true
            }
            self = .dictionary(entries)
        default:
            self = .other(String(cString: xpc_type_get_name(type)))
        }
    }
}
