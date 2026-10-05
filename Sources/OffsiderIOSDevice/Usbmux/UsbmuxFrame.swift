import Foundation

/// One usbmuxd message: a 16-byte little-endian header (length, version, type, tag) and an XML plist payload.
public struct UsbmuxFrame: Equatable, Sendable {
    public static let headerSize = 16
    public static let version: UInt32 = 1
    public static let plistType: UInt32 = 8
    /// usbmuxd replies are small; anything larger is not a usbmuxd reply.
    public static let maximumLength: UInt32 = 4 * 1024 * 1024

    public struct Header: Equatable, Sendable {
        public let length: UInt32
        public let version: UInt32
        public let type: UInt32
        public let tag: UInt32
    }

    public var tag: UInt32
    public var payload: Data

    public init(tag: UInt32, payload: Data) {
        self.tag = tag
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        for field in [UInt32(Self.headerSize + payload.count), Self.version, Self.plistType, tag] {
            withUnsafeBytes(of: field.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    public static func header(_ bytes: Data) throws -> Header {
        guard bytes.count >= headerSize else { throw UsbmuxError.malformed("a short header") }
        let fields = (0..<4).map { index in
            bytes.dropFirst(index * 4).prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }
        let header = Header(length: fields[0], version: fields[1], type: fields[2], tag: fields[3])
        guard header.length >= headerSize, header.length <= maximumLength else {
            throw UsbmuxError.malformed("a frame length of \(header.length)")
        }
        guard header.version == version, header.type == plistType else {
            throw UsbmuxError.malformed("version \(header.version), type \(header.type)")
        }
        return header
    }

    public static func decode(_ bytes: Data) throws -> UsbmuxFrame {
        let header = try header(bytes)
        guard bytes.count == Int(header.length) else { throw UsbmuxError.malformed("\(bytes.count) bytes for a \(header.length)-byte frame") }
        return UsbmuxFrame(tag: header.tag, payload: Data(bytes.dropFirst(headerSize)))
    }
}

/// What can go wrong talking to usbmuxd, before it is turned into a user-facing `IOSDeviceError`.
public enum UsbmuxError: Error, Equatable, Sendable {
    case socketUnavailable(String)
    case timedOut
    case closed
    case malformed(String)
    /// usbmuxd's `Result` number: 2 bad device, 3 connection refused, 5 malformed request.
    case result(Int)
    case notOnUSB
    case notAttached
}
