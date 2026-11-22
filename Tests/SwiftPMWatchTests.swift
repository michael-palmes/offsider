import Foundation
import Testing

@Suite("SwiftPM watch manifest")
struct SwiftPMWatchTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let watch = root.appendingPathComponent(".github/swiftpm-watch")

    struct Resolved: Decodable {
        struct Pin: Decodable, Equatable {
            struct State: Decodable, Equatable {
                let revision: String
                let version: String?
            }
            let identity: String
            let location: String
            let state: State
        }
        let pins: [Pin]
    }

    private static func pins(in directory: URL) throws -> [String: Resolved.Pin] {
        let data = try Data(contentsOf: directory.appendingPathComponent("Package.resolved"))
        let resolved = try JSONDecoder().decode(Resolved.self, from: data)
        return Dictionary(uniqueKeysWithValues: resolved.pins.map { ($0.identity, $0) })
    }

    private static func requirements(in directory: URL) throws -> [String] {
        let manifest = try String(contentsOf: directory.appendingPathComponent("Package.swift"), encoding: .utf8)
        return manifest.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".package(url:") }
    }

    @Test("Dependabot sees exactly the pins the root manifest builds with")
    func watchPinsMatchRootPins() throws {
        let root = try Self.pins(in: Self.root)
        let watch = try Self.pins(in: Self.watch)
        #expect(!root.isEmpty)
        for (identity, pin) in root {
            #expect(watch[identity] == pin, "\(identity) is pinned differently in .github/swiftpm-watch/Package.resolved; make the same change in both Package.resolved files")
        }
        #expect(Set(watch.keys).subtracting(root.keys).isEmpty, "the watch manifest pins packages the root does not")
    }

    @Test("the watch manifest asks for exactly the root manifest's remote requirements")
    func watchRequirementsMatchRoot() throws {
        let root = try Self.requirements(in: Self.root)
        let watch = try Self.requirements(in: Self.watch)
        #expect(!root.isEmpty)
        #expect(watch.sorted() == root.sorted(), "copy every .package(url:) line of the root Package.swift into .github/swiftpm-watch/Package.swift")
    }
}
