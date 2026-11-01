import Compression
import Darwin
import Foundation

/// An APK opened once, so the package read from it and the bytes sent to the device are the same file.
public final class ApkFile: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case missing
        case notRegularFile
        case unreadable
    }

    public let path: String
    public let size: Int
    private let descriptor: Int32

    public init(path: String) throws {
        // Follows a symlink, as a person's `latest.apk` may be one; never blocks on a FIFO.
        let opened = unsafe open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw errno == ENOENT || errno == ENOTDIR ? Failure.missing : Failure.unreadable }
        var status = stat()
        guard unsafe fstat(opened, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            close(opened)
            throw Failure.notRegularFile
        }
        self.path = path
        size = Int(status.st_size)
        descriptor = opened
    }

    deinit { close(descriptor) }

    /// Exactly `count` bytes at `offset`, or nil when the file holds fewer.
    public func read(at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset <= size, count <= size - offset else { return nil }
        var data = Data(count: count)
        var done = 0
        while done < count {
            let got = unsafe data.withUnsafeMutableBytes { unsafe pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset + done)) }
            if got <= 0 { return nil }
            done += got
        }
        return data
    }
}

/// The package an APK declares, read from its zip and binary manifest with no SDK tool. The device checks it again on install.
public enum ApkManifest {
    public enum Failure: Error, Equatable, Sendable {
        case notZip
        case noManifest
        case twoManifests
        case unreadableManifest
    }

    static let manifestName = "AndroidManifest.xml"
    static let maximumCentralDirectory = 32 << 20
    static let maximumManifest = 16 << 20
    static let endRecordBytes = 22
    static let maximumComment = 0xFFFF

    public static func package(of file: ApkFile) throws(Failure) -> String {
        try package(size: file.size) { file.read(at: $0, count: $1) }
    }

    /// Zip64 is refused: an APK under 4 GB has no need of it, and Android's own zip reader does not take it.
    static func package(size: Int, read: (_ offset: Int, _ count: Int) -> Data?) throws(Failure) -> String {
        let entry = try manifestEntry(size: size, read: read)
        let bytes = try manifestBytes(entry, size: size, read: read)
        guard let package = packageName(fromBinaryXML: bytes), (try? ExpoDevClient.validate(appID: package)) != nil else { throw .unreadableManifest }
        return package
    }

    struct Entry: Equatable {
        let method: Int
        let compressed: Int
        let uncompressed: Int
        let localOffset: Int
    }

    private static func manifestEntry(size: Int, read: (Int, Int) -> Data?) throws(Failure) -> Entry {
        guard size >= endRecordBytes else { throw .notZip }
        let tailCount = min(size, endRecordBytes + maximumComment)
        guard let tail = read(size - tailCount, tailCount).map(Bytes.init), let end = endRecord(in: tail) else { throw .notZip }
        guard let directorySize = tail.u32(end + 12), let directoryOffset = tail.u32(end + 16),
              directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF,
              directorySize <= maximumCentralDirectory,
              let directory = read(directoryOffset, directorySize).map(Bytes.init) else { throw .notZip }
        var found: Entry?
        var position = 0
        while let signature = directory.u32(position), signature == 0x0201_4B50 {
            guard let method = directory.u16(position + 10), let compressed = directory.u32(position + 20), let uncompressed = directory.u32(position + 24),
                  let nameLength = directory.u16(position + 28), let extraLength = directory.u16(position + 30), let commentLength = directory.u16(position + 32),
                  let localOffset = directory.u32(position + 42), let name = directory.slice(position + 46, nameLength) else { throw .notZip }
            if name.elementsEqual(manifestName.utf8) {
                guard found == nil else { throw .twoManifests }
                found = Entry(method: method, compressed: compressed, uncompressed: uncompressed, localOffset: localOffset)
            }
            position += 46 + nameLength + extraLength + commentLength
        }
        guard let found else { throw .noManifest }
        return found
    }

    /// The last end record whose comment runs exactly to the end of the file.
    private static func endRecord(in tail: Bytes) -> Int? {
        var position = tail.count - endRecordBytes
        while position >= 0 {
            if tail.u32(position) == 0x0605_4B50, let comment = tail.u16(position + 20), position + endRecordBytes + comment == tail.count { return position }
            position -= 1
        }
        return nil
    }

    private static func manifestBytes(_ entry: Entry, size: Int, read: (Int, Int) -> Data?) throws(Failure) -> Data {
        guard entry.compressed <= maximumManifest, entry.uncompressed <= maximumManifest,
              let header = read(entry.localOffset, 30).map(Bytes.init), header.u32(0) == 0x0403_4B50,
              let nameLength = header.u16(26), let extraLength = header.u16(28),
              let stored = read(entry.localOffset + 30 + nameLength + extraLength, entry.compressed) else { throw .unreadableManifest }
        switch entry.method {
        case 0:
            return stored
        case 8:
            guard let inflated = inflate(stored, expecting: entry.uncompressed) else { throw .unreadableManifest }
            return inflated
        default:
            throw .unreadableManifest
        }
    }

    private static func inflate(_ data: Data, expecting count: Int) -> Data? {
        guard count > 0, !data.isEmpty else { return nil }
        var output = Data(count: count)
        let written = unsafe output.withUnsafeMutableBytes { target in
            unsafe data.withUnsafeBytes { source in
                unsafe compression_decode_buffer(
                    target.bindMemory(to: UInt8.self).baseAddress!, count,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return written == count ? output : nil
    }

    // MARK: Binary XML

    /// The `package` attribute of the first element, which must be `manifest`.
    static func packageName(fromBinaryXML data: Data) -> String? {
        let xml = Bytes(data)
        guard xml.u16(0) == 0x0003, let headerSize = xml.u16(2), headerSize >= 8 else { return nil }
        var strings: StringPool?
        var position = headerSize
        var chunks = 0
        while chunks < 1 << 16, let type = xml.u16(position), let size = xml.u32(position + 4), size >= 8, position + size <= xml.count {
            chunks += 1
            switch type {
            case 0x0001 where strings == nil:
                strings = StringPool(xml, at: position, size: size)
            case 0x0102:
                guard let strings else { return nil }
                return packageAttribute(xml, element: position, strings: strings)
            default:
                break
            }
            position += size
        }
        return nil
    }

    private static func packageAttribute(_ xml: Bytes, element: Int, strings: StringPool) -> String? {
        guard let name = xml.u32(element + 20), strings[name] == "manifest",
              let start = xml.u16(element + 24), let attributeSize = xml.u16(element + 26), attributeSize >= 20, let count = xml.u16(element + 28) else { return nil }
        for index in 0..<count {
            let attribute = element + 16 + start + index * attributeSize
            guard let namespace = xml.u32(attribute), let attributeName = xml.u32(attribute + 4), let raw = xml.u32(attribute + 8) else { return nil }
            guard namespace == 0xFFFF_FFFF, strings[attributeName] == "package" else { continue }
            if let text = strings[raw] { return text }
            guard xml.byte(attribute + 15) == 3, let typed = xml.u32(attribute + 16) else { return nil }
            return strings[typed]
        }
        return nil
    }

    private struct StringPool {
        let xml: Bytes
        let pool: Int
        let end: Int
        let count: Int
        let utf8: Bool
        let stringsStart: Int
        let offsets: Int

        init?(_ xml: Bytes, at pool: Int, size: Int) {
            guard let headerSize = xml.u16(pool + 2), let count = xml.u32(pool + 8), let flags = xml.u32(pool + 16), let start = xml.u32(pool + 20) else { return nil }
            self.xml = xml
            self.pool = pool
            end = pool + size
            self.count = count
            utf8 = flags & 0x100 != 0
            stringsStart = start
            offsets = pool + headerSize
        }

        subscript(index: Int) -> String? {
            guard index >= 0, index < count, let offset = xml.u32(offsets + index * 4) else { return nil }
            let at = pool + stringsStart + offset
            return utf8 ? utf8String(at) : utf16String(at)
        }

        /// Two lengths come first: characters, then bytes; each takes a second byte when its high bit is set.
        private func utf8String(_ start: Int) -> String? {
            var at = start
            guard let first = xml.byte(at) else { return nil }
            at += first & 0x80 != 0 ? 2 : 1
            guard let high = xml.byte(at) else { return nil }
            var length = high
            at += 1
            if high & 0x80 != 0 {
                guard let low = xml.byte(at) else { return nil }
                length = (high & 0x7F) << 8 | low
                at += 1
            }
            guard at + length <= end, let bytes = xml.slice(at, length) else { return nil }
            return String(validating: bytes, as: UTF8.self)
        }

        private func utf16String(_ start: Int) -> String? {
            guard var length = xml.u16(start) else { return nil }
            var at = start + 2
            if length & 0x8000 != 0 {
                guard let low = xml.u16(at) else { return nil }
                length = (length & 0x7FFF) << 16 | low
                at += 2
            }
            guard length <= 4096, at + length * 2 <= end else { return nil }
            var units: [UInt16] = []
            for index in 0..<length {
                guard let unit = xml.u16(at + index * 2) else { return nil }
                units.append(UInt16(unit))
            }
            return String(validating: units, as: UTF16.self)
        }
    }

    /// Little-endian reads that answer nil past the end, so a malformed file cannot trap.
    struct Bytes {
        let storage: [UInt8]

        init(_ data: Data) { storage = [UInt8](data) }

        var count: Int { storage.count }

        func byte(_ at: Int) -> Int? {
            at >= 0 && at < storage.count ? Int(storage[at]) : nil
        }

        func u16(_ at: Int) -> Int? {
            guard at >= 0, at <= storage.count - 2 else { return nil }
            return Int(storage[at]) | Int(storage[at + 1]) << 8
        }

        func u32(_ at: Int) -> Int? {
            guard at >= 0, at <= storage.count - 4 else { return nil }
            return Int(storage[at]) | Int(storage[at + 1]) << 8 | Int(storage[at + 2]) << 16 | Int(storage[at + 3]) << 24
        }

        func slice(_ at: Int, _ length: Int) -> ArraySlice<UInt8>? {
            guard at >= 0, length >= 0, at <= storage.count, length <= storage.count - at else { return nil }
            return storage[at..<(at + length)]
        }
    }
}
