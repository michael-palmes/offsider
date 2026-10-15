import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("offsider.mask.json")
struct MaskConfigTests {
    private static func parse(_ text: String) throws -> MaskConfig {
        try MaskConfig.parse(Data(text.utf8), path: "/repo/offsider.mask.json")
    }

    private static func failure(_ text: String) -> String? {
        do {
            _ = try parse(text)
            return nil
        } catch let error as MaskConfigError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test("every key parses, comments are allowed, and it joins the screenshot masks")
    func parsesEveryKey() throws {
        let config = try Self.parse("""
        {
          "//ids": "Accessibility ids whose element is painted and whose value is hidden.",
          "ids": ["balance-label"],
          "labels": ["Account number"],
          "labelContains": ["Balance"],
          "valuePatterns": ["[0-9]{3}-[0-9]{3}"],
          "emails": true
        }
        """)
        #expect(config == MaskConfig(ids: ["balance-label"], labels: ["Account number"], labelContains: ["Balance"], valuePatterns: ["[0-9]{3}-[0-9]{3}"], emails: true))
        #expect(config.plan == MaskPlan(ids: ["balance-label"], labels: ["Account number"], labelsContaining: ["Balance"], texts: ["[0-9]{3}-[0-9]{3}"], emails: true))
        #expect(try Self.parse("{}").isEmpty)
    }

    @Test("the shipped example parses")
    func exampleParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("offsider.mask.example.json")
        let config = try MaskConfig.parse(try Data(contentsOf: url))
        #expect(!config.isEmpty)
    }

    @Test("a mistake names the file and its line", arguments: [
        ("{\n  \"ids\": [\"a\"],\n  \"colour\": 1\n}", "/repo/offsider.mask.json line 3: unknown key colour"),
        ("{\n  \"ids\": \"a\"\n}", "/repo/offsider.mask.json line 2: ids must be a list of strings."),
        ("{\n\n  \"emails\": \"yes\"\n}", "/repo/offsider.mask.json line 3: emails must be true or false."),
        ("{\n  \"labels\": [\" \"]\n}", "/repo/offsider.mask.json line 2: labels has an empty entry."),
        ("{\n  \"//\": 1\n}", "/repo/offsider.mask.json line 2: the comment // must be a string."),
        ("[1]", "/repo/offsider.mask.json must be a JSON object."),
    ])
    func mistakes(text: String, message: String) {
        #expect(Self.failure(text)?.hasPrefix(message) == true, "\(Self.failure(text) ?? "parsed")")
    }

    @Test("broken JSON names the line the parser stopped at")
    func brokenJSON() {
        #expect(Self.failure("{\n  \"ids\": [\"a\",]\n  \"x\"\n}")?.hasPrefix("/repo/offsider.mask.json line ") == true)
    }

    @Test("a value pattern must compile and have a bounded count", arguments: [
        ("[0-9]{6}", true), ("\\d{4,19}", true), ("a\\*b", true), ("[*+]{1,3}", true),
        ("[0-9]+", false), ("a*", false), ("x{2,}", false), ("(", false),
    ])
    func patterns(pattern: String, accepted: Bool) {
        #expect((MaskConfig.patternProblem(pattern) == nil) == accepted)
    }

    @Test("too many entries or a too-long pattern are refused")
    func limits() {
        let many = (0...MaskConfig.maximumEntries).map { "\"id\($0)\"" }.joined(separator: ",")
        #expect(Self.failure("{\"ids\": [\(many)]}")?.contains("more than 64 entries") == true)
        #expect(MaskConfig.patternProblem(String(repeating: "a", count: 201)) != nil)
    }

    @Test("the loader finds the file up to the repository root and reports a bad one as a usage error")
    func loader() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-mask-\(UUID().uuidString)")
        let nested = (root as NSString).appendingPathComponent("app/src")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        #expect(try MaskConfigs.load(from: nested) == nil)
        let file = (root as NSString).appendingPathComponent(MaskConfig.fileName)
        try Data(#"{"ids": ["balance"]}"#.utf8).write(to: URL(fileURLWithPath: file))
        #expect(try MaskConfigs.load(from: nested)?.config.ids == ["balance"])

        try Data(#"{"ids": 1}"#.utf8).write(to: URL(fileURLWithPath: file))
        let error = #expect(throws: CLIError.self) { try MaskConfigs.load(from: nested) }
        #expect(error?.reason == .usage)
        #expect(error?.userFacingDescription.hasSuffix("ids must be a list of strings. Fix the file, or move it aside.") == true)
    }
}
