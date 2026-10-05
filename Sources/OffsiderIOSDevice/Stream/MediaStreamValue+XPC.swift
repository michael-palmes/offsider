import Foundation
import XPC

extension MediaStreamValue {
    var xpcObject: xpc_object_t {
        switch self {
        case .string(let value): return xpc_string_create(value)
        case .bool(let value): return xpc_bool_create(value)
        case .int(let value): return xpc_int64_create(value)
        case .uint(let value): return xpc_uint64_create(value)
        case .double(let value): return xpc_double_create(value)
        case .data(let value): return value.withUnsafeBytes { xpc_data_create($0.baseAddress, value.count) }
        case .uuid(let value):
            var raw = value.uuid
            return withUnsafeBytes(of: &raw) { xpc_uuid_create($0.bindMemory(to: UInt8.self).baseAddress!) }
        case .array(let values):
            let array = xpc_array_create(nil, 0)
            for value in values { xpc_array_append_value(array, value.xpcObject) }
            return array
        case .dictionary(let entries):
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            for (key, value) in entries { xpc_dictionary_set_value(dictionary, key, value.xpcObject) }
            return dictionary
        }
    }

    /// Nil for types the stream actions never carry, such as file descriptors.
    init?(xpc object: xpc_object_t) {
        let type = xpc_get_type(object)
        switch type {
        case XPC_TYPE_STRING:
            self = .string(String(cString: xpc_string_get_string_ptr(object)!))
        case XPC_TYPE_BOOL:
            self = .bool(xpc_bool_get_value(object))
        case XPC_TYPE_INT64:
            self = .int(xpc_int64_get_value(object))
        case XPC_TYPE_UINT64:
            self = .uint(xpc_uint64_get_value(object))
        case XPC_TYPE_DOUBLE:
            self = .double(xpc_double_get_value(object))
        case XPC_TYPE_DATA:
            let count = xpc_data_get_length(object)
            self = .data(xpc_data_get_bytes_ptr(object).map { Data(bytes: $0, count: count) } ?? Data())
        case XPC_TYPE_UUID:
            guard let bytes = xpc_uuid_get_bytes(object) else { return nil }
            self = .uuid(NSUUID(uuidBytes: bytes) as UUID)
        case XPC_TYPE_ARRAY:
            var values: [MediaStreamValue] = []
            xpc_array_apply(object) { _, value in
                if let converted = MediaStreamValue(xpc: value) { values.append(converted) }
                return true
            }
            self = .array(values)
        case XPC_TYPE_DICTIONARY:
            var entries: [String: MediaStreamValue] = [:]
            xpc_dictionary_apply(object) { key, value in
                if let converted = MediaStreamValue(xpc: value) { entries[String(cString: key)] = converted }
                return true
            }
            self = .dictionary(entries)
        default:
            return nil
        }
    }
}
