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

    /// Each row of the "## Keys" table: the key and its type cell.
    static func documentedRows() throws -> [(key: String, type: String)] {
        let text = try String(contentsOf: root.appendingPathComponent("docs/mdm.md"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "## Keys"), "docs/mdm.md has no \"## Keys\" section")
        let rows = lines[(start + 1)...].prefix { !$0.hasPrefix("#") }.filter { $0.hasPrefix("| ") && !$0.hasPrefix("| ---") }.dropFirst()
        return rows.compactMap { row in
            let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { return nil }
            return (cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`")), cells[1])
        }
    }

    static func readKeys() -> Set<String> {
        let recorder = KeyRecorder()
        _ = ManagedDevicePolicy.read(from: recorder)
        return recorder.keys
    }

    @Test("docs/mdm.md lists every key the managed policy reads, and no other")
    func keyTableMatchesPolicy() throws {
        let read = Self.readKeys()
        let documented = try Self.documentedRows().map(\.key)
        #expect(read == Set(ManagedDevicePolicy.knownKeys))
        #expect(Set(documented).count == documented.count, "a key is listed twice")
        for key in read.sorted() {
            #expect(documented.contains(key), "docs/mdm.md has no row for \(key)")
        }
        for key in documented where !read.contains(key) {
            Issue.record("docs/mdm.md lists \(key), which ManagedDevicePolicy never reads")
        }
    }

    @Test("the JSON schema has a described property for every key, typed as the page says, and no other")
    func schemaMatchesPolicy() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("docs/mdm/com.mpalmes.offsider.schema.json"))
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(properties.keys) == Self.readKeys())
        for row in try Self.documentedRows() {
            let property = try #require(properties[row.key], "the schema has no property for \(row.key)")
            let type = try #require(property["type"] as? String)
            #expect(row.type.hasPrefix(type == "array" ? "array of strings" : type), "\(row.key) is \(type) in the schema and \"\(row.type)\" on the page")
            if type == "array" { #expect((property["items"] as? [String: String])?["type"] == "string") }
            #expect((property["title"] as? String)?.isEmpty == false && (property["description"] as? String)?.isEmpty == false, "\(row.key) has no title or description")
        }
        let days = try #require(properties[ManagedCeilings.maxAllowanceDaysKey])
        #expect(days["minimum"] as? Int == 1 && days["maximum"] as? Int == ManagedCeilings.longestAllowanceDays)
    }

    @Test("the sample profile forces only keys Offsider reads")
    func sampleProfileKeys() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("docs/mdm.md"), encoding: .utf8)
        let settings = try #require(text.range(of: "<key>mcx_preference_settings</key>"))
        let block = text[settings.upperBound...].prefix { _ in true }
        let end = try #require(block.range(of: "</dict>"))
        let keys = block[..<end.lowerBound].split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<key>"), trimmed.hasSuffix("</key>") else { return nil }
            return String(trimmed.dropFirst(5).dropLast(6))
        }
        #expect(keys.count >= 5)
        for key in keys { #expect(ManagedDevicePolicy.knownKeys.contains(key), "the sample profile forces \(key), which Offsider does not know") }
    }
}
