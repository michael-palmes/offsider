import CryptoKit
import Darwin
import Foundation
import OffsiderCore

/// `<key>/products.json`: who a runner build was made for and the sha256 of each product, so a changed product is never installed.
public struct RunnerProductsRecord: Codable, Equatable, Sendable {
    public var version: Int
    public var udid: String
    public var team: String?
    public var prefix: String
    /// Keyed by path below `derived/Build/Products`.
    public var products: [String: String]

    public init(udid: String, team: String?, prefix: String, products: [String: String]) {
        version = 1
        self.udid = udid
        self.team = team
        self.prefix = prefix
        self.products = products
    }
}

enum RunnerProducts {
    static let fileName = "products.json"
    static let maxRecordBytes = 4 << 20

    static func productsDirectory(_ directory: URL) -> URL {
        directory.appendingPathComponent("derived/Build/Products", isDirectory: true)
    }

    /// Every file inside a built `.app` and every `.xctestrun`; a symlink is recorded by its target.
    static func digests(in directory: URL) throws -> [String: String] {
        let root = productsDirectory(directory)
        let base = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [:] }
        var digests: [String: String] = [:]
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let inBundle = relative.split(separator: "/").contains { $0.hasSuffix(".app") }
            guard inBundle || relative.hasSuffix(".xctestrun") else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                digests[relative] = "symlink:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")
            } else if values.isRegularFile == true {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                digests[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return digests
    }

    struct Bundles {
        var paths: [String] = []
        var hasHostApp = false
        var hasRunnerApp = false
        var hasTestBundle = false
    }

    /// The host app, the `-Runner.app` and the `.xctest` bundles a build installs.
    static func signedBundles(in directory: URL) -> Bundles {
        let root = productsDirectory(directory)
        var bundles = Bundles()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return bundles }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasSuffix(".app") || name.hasSuffix(".xctest") {
                bundles.paths.append(url.path)
                if name.hasSuffix("-Runner.app") {
                    bundles.hasRunnerApp = true
                } else if name.hasSuffix(".app") {
                    bundles.hasHostApp = true
                } else {
                    bundles.hasTestBundle = true
                }
            }
            if name.hasSuffix(".xctest") || name == "Frameworks" { walker.skipDescendants() }
        }
        bundles.paths.sort()
        return bundles
    }

    /// Replaces any record with a new 0600 file.
    static func write(_ record: RunnerProductsRecord, in directory: URL) throws {
        let path = directory.appendingPathComponent(fileName).path
        unlink(path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try RunFolder.writeNew(try encoder.encode(record), toPath: path)
    }

    static func read(in directory: URL) throws -> RunnerProductsRecord? {
        guard let data = try OffsiderPrivateDirectory.readOwnedFile(named: fileName, in: directory.path, maxBytes: maxRecordBytes) else { return nil }
        return try JSONDecoder().decode(RunnerProductsRecord.self, from: data)
    }
}
