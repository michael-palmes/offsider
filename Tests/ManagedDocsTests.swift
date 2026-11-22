import Foundation
import OffsiderCore
import Testing

@Suite("Managed Macs docs")
struct ManagedDocsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    final class KeyRecorder: ManagedPreferenceSource, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []

        var keys: Set<String> { lock.withLock { Set(asked) } }

        func forcedValue(forKey key: String) -> ManagedPreferenceValue? {
            lock.withLock { asked.append(key) }
            return nil
        }

        func forcedKeys() -> [String] { [] }
    }

    static func documentedKeys() throws -> [String] {
        let text = try String(contentsOf: root.appendingPathComponent("docs/mdm.md"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "## Keys"), "docs/mdm.md has no \"## Keys\" section")
        let rows = lines[(start + 1)...].prefix { !$0.hasPrefix("#") }.filter { $0.hasPrefix("| ") && !$0.hasPrefix("| ---") }.dropFirst()
        return rows.compactMap { row in
            row.split(separator: "|").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " `")) }
        }
    }

    @Test("docs/mdm.md lists every key the managed policy reads, and no other")
    func keyTableMatchesPolicy() throws {
        let recorder = KeyRecorder()
        _ = ManagedDevicePolicy.read(from: recorder)
        let documented = try Self.documentedKeys()
        #expect(!recorder.keys.isEmpty)
        #expect(Set(documented).count == documented.count, "a key is listed twice")
        for key in recorder.keys.sorted() {
            #expect(documented.contains(key), "docs/mdm.md has no row for \(key)")
        }
        for key in documented where !recorder.keys.contains(key) {
            Issue.record("docs/mdm.md lists \(key), which ManagedDevicePolicy never reads")
        }
    }
}
