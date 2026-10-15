import Foundation

extension OrderedJSON {
    enum ParseError: Error, Equatable {
        case invalid(offset: Int)
        case tooDeep
        case duplicateKey(String)
    }

    /// Strict RFC 8259 parsing that keeps object keys in file order; duplicate keys are refused.
    static func parse(_ data: Data, maxDepth: Int = 64) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data), maxDepth: maxDepth)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError.invalid(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        let maxDepth: Int
        var index = 0

        init(bytes: [UInt8], maxDepth: Int) {
            self.bytes = bytes
            self.maxDepth = maxDepth
        }

        var invalid: ParseError { .invalid(offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw invalid }
                index += 1
            }
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth <= maxDepth else { throw ParseError.tooDeep }
            guard index < bytes.count else { throw invalid }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try number()
            }
        }

        mutating func object(depth: Int) throws -> OrderedJSON {
            index += 1
            var members: [(String, OrderedJSON)] = []
            var keys = Set<String>()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw invalid }
                let key = try string()
                guard keys.insert(key).inserted else { throw ParseError.duplicateKey(key) }
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                members.append((key, try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw invalid }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw invalid
            }
        }

        mutating func array(depth: Int) throws -> OrderedJSON {
            index += 1
            var elements: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw invalid }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                throw invalid
            }
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run: [UInt8] = []
            func flush() throws {
                guard !run.isEmpty else { return }
                guard let text = String(validating: run, as: UTF8.self) else { throw invalid }
                scalars.append(contentsOf: text.unicodeScalars)
                run.removeAll(keepingCapacity: true)
            }
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    try flush()
                    index += 1
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    try flush()
                    index += 1
                    guard index < bytes.count else { throw invalid }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code) {
                            try expect("\\u")
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw invalid }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw invalid }
                        scalars.append(scalar)
                    default:
                        throw invalid
                    }
                default:
                    guard byte >= 0x20 else { throw invalid }
                    run.append(byte)
                    index += 1
                }
            }
            throw invalid
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw invalid }
            var value: UInt32 = 0
            for byte in bytes[index..<index + 4] {
                guard let digit = UInt32(String(UnicodeScalar(byte)), radix: 16) else { throw invalid }
                value = value << 4 | digit
            }
            index += 4
            return value
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            func digits() -> Int {
                let from = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - from
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw invalid }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if digits() == 0 {
                throw invalid
            }
            var integral = true
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                integral = false
                index += 1
                guard digits() > 0 else { throw invalid }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                integral = false
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw invalid }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if integral, let value = Int(text) { return .integer(value) }
            guard let value = Double(text), value.isFinite else { throw invalid }
            return .number(value)
        }
    }
}
