import Foundation
import Testing

@Suite("SwiftPM watch manifest")
struct SwiftPMWatchTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let watch = root.appendingPathComponent("swiftpm-watch")

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
            #expect(watch[identity] == pin, "\(identity) is pinned differently in swiftpm-watch/Package.resolved; make both Package.resolved files agree (on a Dependabot pull request, move the root to match)")
        }
        #expect(Set(watch.keys).subtracting(root.keys).isEmpty, "the watch manifest pins packages the root does not")
    }

    @Test("the watch manifest asks for exactly the root manifest's remote requirements")
    func watchRequirementsMatchRoot() throws {
        let root = try Self.requirements(in: Self.root)
        let watch = try Self.requirements(in: Self.watch)
        #expect(!root.isEmpty)
        #expect(watch.sorted() == root.sorted(), "the .package(url:) lines of Package.swift and swiftpm-watch/Package.swift differ; make them the same (on a Dependabot pull request, change the root to match)")
    }

    @Test("Dependabot reads the watch manifest from a folder it may open pull requests for")
    func dependabotReadsTheWatchFolderOutsideDotGitHub() throws {
        let config = try String(contentsOf: Self.root.appendingPathComponent(".github/dependabot.yml"), encoding: .utf8)
        let lines = config.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let swift = try #require(lines.firstIndex(of: "- package-ecosystem: swift"))
        let entry = lines[(swift + 1)...].prefix { !$0.hasPrefix("- package-ecosystem:") }
        #expect(entry.contains("directory: /\(Self.watch.lastPathComponent)"), "dependabot.yml's swift entry must read \(Self.watch.lastPathComponent)/")
        #expect(!entry.contains { $0.hasPrefix("directory: /.github") || $0.hasPrefix("- /.github") }, "Dependabot's pull request for a folder under .github/ is refused (HTTP 400) for every ecosystem but github-actions: dependabot/dependabot-core#15237")
    }
}
