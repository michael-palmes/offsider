import CryptoKit
import Foundation

/// The on-device helper's dex, checked against the manifest built beside it.
public struct HelperDex: Equatable, Sendable {
    /// The wire protocol this Offsider speaks; the manifest, the ready line and `hello` must all agree.
    public static let protocolVersion = 2

    public let bytes: Data
    /// 64 lower-case hex digits.
    public let sha256: String
    /// The manifest's `helperVersion`.
    public let version: String

    /// Decodes the manifest and checks the dex's size and SHA-256 and the protocol against it.
    public init(bytes: Data, manifestJSON: Data) throws {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestJSON)
        } catch {
            throw HelperDexError.damaged("the manifest is unreadable: \(error.localizedDescription)")
        }
        guard bytes.count == manifest.dex.bytes else {
            throw HelperDexError.damaged("the dex has \(bytes.count) bytes, its manifest says \(manifest.dex.bytes)")
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.dex.sha256.lowercased() else {
            throw HelperDexError.damaged("the dex has sha256 \(digest), its manifest says \(manifest.dex.sha256)")
        }
        guard manifest.protocol == Self.protocolVersion else {
            throw HelperDexError.protocolMismatch(found: manifest.protocol, expected: Self.protocolVersion)
        }
        self.bytes = bytes
        sha256 = digest
        version = manifest.helperVersion
    }

    /// Content-addressed, so the name proves the content and the start script only checks the size.
    var devicePath: String {
        "/data/local/tmp/offsider-helper-\(sha256.prefix(16)).dex"
    }

    private struct Manifest: Decodable {
        struct Dex: Decodable {
            let bytes: Int
            let sha256: String
        }

        let helperVersion: String
        let `protocol`: Int
        let dex: Dex
    }
}

public enum HelperDexError: Error, Equatable, Sendable, CustomStringConvertible {
    case notBundled(String)
    case damaged(String)
    case protocolMismatch(found: Int, expected: Int)

    public var description: String {
        switch self {
        case .notBundled(let detail):
            return "no helper is bundled (\(detail))"
        case .damaged(let detail):
            return "the bundled helper is damaged (\(detail))"
        case .protocolMismatch(let found, let expected):
            return "the bundled helper speaks protocol \(found), Offsider speaks \(expected)"
        }
    }
}
