import Darwin
import Foundation

/// Reads a file another process may have planted: never follows a final symlink, never blocks on a FIFO, never reads a device, never past a cap.
public enum UntrustedRead {
    /// Enough for any `config.ini`, pid file or key listing Offsider reads.
    public static let defaultMaxBytes = 1 << 20

    public enum Failure: Error, Equatable, Sendable {
        /// Nothing at the path.
        case missing
        /// The last path component is a symlink.
        case symlink
        /// A FIFO, socket, device or folder rather than a regular file.
        case notRegularFile
        /// Larger than the caller's cap.
        case tooLarge(maxBytes: Int)
        /// `open`, `fstat` or `read` failed with this `errno`.
        case system(code: Int32)
    }

    /// The file's bytes, at most `maxBytes`; a larger file is refused unless `truncate`, which keeps its first `maxBytes`.
    public static func data(atPath path: String, maxBytes: Int = defaultMaxBytes, truncate: Bool = false) throws(Failure) -> Data {
        let descriptor = unsafe open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw .missing
            case ELOOP: throw .symlink
            default: throw .system(code: errno)
            }
        }
        defer { close(descriptor) }
        var status = stat()
        guard unsafe fstat(descriptor, &status) == 0 else { throw .system(code: errno) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw .notRegularFile }
        let cap = max(0, maxBytes)
        if !truncate, status.st_size > off_t(cap) { throw .tooLarge(maxBytes: cap) }

        let limit = truncate ? cap : cap + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, max(1, limit)))
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let count = buffer.withUnsafeMutableBytes { unsafe Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .system(code: errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count <= cap else { throw .tooLarge(maxBytes: cap) }
        return data
    }

    /// `data(atPath:)` as an optional, for callers that treat any refusal as "no file".
    public static func contents(atPath path: String, maxBytes: Int = defaultMaxBytes, truncate: Bool = false) -> Data? {
        try? data(atPath: path, maxBytes: maxBytes, truncate: truncate)
    }
}
