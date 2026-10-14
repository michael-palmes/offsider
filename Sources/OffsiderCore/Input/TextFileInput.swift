import Darwin
import Foundation

/// Text for `type --file` and `batch --file`: a regular UTF-8 file of at most 64 KiB, never one in a folder that holds secrets.
public enum TextFileInput {
    public static let maxBytes = 65_536

    /// Folders under the home directory that hold keys, tokens or Offsider's own records.
    static let homePrefixes = [
        ".ssh", ".aws", ".config", ".gnupg", ".docker", ".kube", "Library/Keychains", "Library/Application Support/offsider",
    ]
    static let systemPrefixes = ["/etc", "/private/etc"]
    static let exactNames: Set<String> = [".env", ".netrc", ".git-credentials", ".npmrc", ".pypirc"]
    static let suffixes = [".pem", ".p12", ".key"]

    public struct Text: Equatable, Sendable {
        public let text: String
        public let resolvedPath: String
        public let byteCount: Int

        /// The stderr line every read prints, so a person sees what reached the device.
        public var announcement: String { "Reading text from \(resolvedPath) (\(byteCount) bytes)" }
    }

    public struct Refused: Error, LocalizedError, OffsiderFailure, Equatable {
        public let message: String

        public var reason: FailureReason { .inputFileRefused }
        public var failureMessage: String { message }
        public var errorDescription: String? { message }
    }

    /// Resolves `path` (relative to `cwd`), refuses sensitive places unless `allowSensitive`, then reads the file it named.
    public static func read(
        _ path: String,
        allowSensitive: Bool,
        home: String? = UserConfigDirectory.home(),
        cwd: String = FileManager.default.currentDirectoryPath
    ) throws -> Text {
        let absolute = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        guard let resolved = realPath(absolute) else {
            throw Refused(message: "Could not open \(path) for --file: \(String(cString: strerror(errno))).")
        }
        if !allowSensitive, let why = sensitivity(of: resolved, home: home) {
            throw Refused(message: "Offsider will not read \(resolved) with --file: \(why). Add --allow-path if you meant that file.")
        }
        let descriptor = open(resolved, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Refused(message: "Could not open \(resolved) for --file: \(String(cString: strerror(errno))).")
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG else {
            throw Refused(message: "\(resolved) is not a regular file, so --file will not read it.")
        }
        var named = stat()
        guard stat(resolved, &named) == 0, named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            throw Refused(message: "\(resolved) changed while Offsider opened it, so --file read nothing. Retry.")
        }
        let data = try readUpTo(maxBytes + 1, from: descriptor, path: resolved)
        guard data.count <= maxBytes else {
            throw Refused(message: "\(resolved) is larger than 64 KiB, the most --file reads.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Refused(message: "\(resolved) is not UTF-8 text, so --file will not read it.")
        }
        return Text(text: text, resolvedPath: resolved, byteCount: data.count)
    }

    /// Why `resolved` is off limits without `--allow-path`, or nil when it may be read.
    static func sensitivity(of resolved: String, home: String?) -> String? {
        let lowered = resolved.lowercased()
        func under(_ prefix: String) -> Bool {
            let folder = prefix.lowercased()
            return lowered == folder || lowered.hasPrefix(folder + "/")
        }
        var homes: [String] = []
        if let home {
            homes.append(home)
            if let real = realPath(home), real != home { homes.append(real) }
        }
        for home in homes {
            for prefix in homePrefixes where under((home as NSString).appendingPathComponent(prefix)) {
                return "it is under ~/\(prefix), which holds keys and tokens"
            }
        }
        for prefix in systemPrefixes where under(prefix) {
            return "it is under \(prefix), which holds system configuration"
        }
        let name = (lowered as NSString).lastPathComponent
        if exactNames.contains(name) || (name.hasPrefix(".env.") && name != ".env.example") || name.hasPrefix("id_")
            || suffixes.contains(where: name.hasSuffix) {
            return "a file named \((resolved as NSString).lastPathComponent) usually holds a secret"
        }
        return nil
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func readUpTo(_ limit: Int, from descriptor: Int32, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Refused(message: "Could not read \(path) for --file: \(String(cString: strerror(errno))).")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}
