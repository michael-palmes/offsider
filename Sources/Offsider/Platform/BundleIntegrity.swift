import CryptoKit
import Foundation
import OffsiderCore

/// Reads a file from Offsider's resource bundle only when its sha256 matches the digest compiled into this binary,
/// so a dex, runner source or skill changed after install is refused rather than used.
enum BundleIntegrity {
    static let maxBytes = 8 << 20

    /// The bytes of `relative` (a path inside the bundle, such as `helper/manifest.json`), hashed once per process.
    static func verifiedData(_ relative: String, in bundle: Bundle = .module, digests: [String: String] = BundleDigests.files) throws -> Data {
        guard let expected = digests[relative] else {
            throw damaged(relative, "it is not part of this build")
        }
        guard let root = bundle.resourceURL else {
            throw damaged(relative, "the resource bundle at \(bundle.bundlePath) has no resources")
        }
        let path = root.appendingPathComponent(relative).path
        let (data, actual): (Data, String)
        if let cached = cached(path) {
            (data, actual) = cached
        } else {
            data = try read(path, relative: relative)
            actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            remember(path, data, actual)
        }
        guard actual == expected else {
            throw damaged(relative, "its contents differ from the ones this build shipped")
        }
        return data
    }

    /// `doctor`'s `install.bundle` check: reads every bundled file through its digest and names the first that differs.
    static func doctorCheck(digests: [String: String] = BundleDigests.files) -> DoctorCheckResult {
        var mismatch: String?
        for path in digests.keys.sorted() {
            do {
                _ = try verifiedData(path, digests: digests)
            } catch let error as CLIError {
                mismatch = error.userFacingDescription
                break
            } catch {
                mismatch = error.localizedDescription
                break
            }
        }
        return DoctorCheckResult(id: .installBundle, verdict: DoctorRules.installBundle(mismatch: mismatch, count: digests.count))
    }

    /// Digests of the runner sources, keyed by their path under `runner/`.
    static func runnerFiles(digests: [String: String] = BundleDigests.files) -> [String: String] {
        var files: [String: String] = [:]
        for (path, digest) in digests where path.hasPrefix("runner/") {
            files[String(path.dropFirst("runner/".count))] = digest
        }
        return files
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Data, String)] = [:]

    private static func cached(_ path: String) -> (Data, String)? {
        lock.withLock { cache[path] }
    }

    private static func remember(_ path: String, _ data: Data, _ digest: String) {
        lock.withLock { cache[path] = (data, digest) }
    }

    private static func read(_ path: String, relative: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw damaged(relative, "it cannot be opened (\(String(cString: strerror(errno))))")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw damaged(relative, "it is not a regular file")
        }
        guard info.st_size <= maxBytes else {
            throw damaged(relative, "it is larger than this build's \(maxBytes >> 20) MB limit")
        }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw damaged(relative, "it could not be read in full") }
            offset += count
        }
        return data
    }

    private static func damaged(_ relative: String, _ why: String) -> CLIError {
        CLIError(
            errorDescription: "Offsider's bundled \(relative) does not match this build: \(why). It may have been changed after install, so Offsider will not use it.",
            reason: .installDamaged,
            hint: "brew reinstall offsider"
        )
    }
}
