import Foundation
import Testing
@testable import Offsider

@Suite("Guide and bundled skill")
struct GuideTests {
    static let skillDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Offsider/Resources/skills/offsider")

    static func read(_ path: String) throws -> String {
        try String(contentsOf: skillDirectory.appendingPathComponent(path), encoding: .utf8)
    }

    static func topicFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: skillDirectory.appendingPathComponent("references").path)
            .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    }

    static func allDocuments() throws -> [(name: String, text: String)] {
        try [("SKILL.md", read("SKILL.md"))] + topicFiles().map { ("references/\($0).md", try read("references/\($0).md")) }
    }

    @Test("the installed skill stays a short router with valid frontmatter")
    func routerSizeAndFrontmatter() throws {
        let skill = try Self.read("SKILL.md")
        #expect(skill.utf8.count < 10_240)
        let lines = skill.components(separatedBy: "\n")
        #expect(lines.first == "---")
        #expect(lines.dropFirst().contains("---"))
        #expect(lines.contains("name: offsider"))
        let description = try #require(lines.first { $0.hasPrefix("description: ") }).dropFirst("description: ".count)
        #expect(!description.isEmpty)
        #expect(description.count < 1024)
        #expect(skill.contains("offsider guide <topic>"))
    }

    @Test("the router table, the bundled topic files and the guide topics agree")
    func routerTableMatchesTopics() throws {
        let lines = try Self.read("SKILL.md").components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "## Topics"))
        let rows = lines[start...].drop { !$0.hasPrefix("| Topic |") }.dropFirst(2).prefix { $0.hasPrefix("| ") }
        let table = rows.map { row -> (String, String) in
            let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            return (cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`")), cells[1])
        }
        #expect(table.map(\.0) == GuideTopic.allCases.map(\.rawValue))
        #expect(table.map(\.1) == GuideTopic.allCases.map(\.readItWhen))
        #expect(try Self.topicFiles() == GuideTopic.allCases.map(\.rawValue).sorted())
    }

    @Test("guide prints each topic exactly as bundled", arguments: GuideTopic.allCases)
    func guidePrintsTopic(_ topic: GuideTopic) async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("guide \(topic.rawValue)")
        #expect(result.exitCode == 0)
        let expected = try Self.read("references/\(topic.rawValue).md")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("guide alone lists every topic with when to read it")
    func guideListsTopics() async throws {
        let output = try await TestHelpers.runOffsiderCommand("guide").output
        for topic in GuideTopic.allCases {
            #expect(output.contains(topic.rawValue), "guide does not list \(topic.rawValue)")
        }
        #expect(output.contains("Maestro"))
    }

    @Test("an unknown or path-like topic exits 64 and names the topics", arguments: ["nope", "../SKILL"])
    func unknownTopicIsUsageError(_ name: String) async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("guide \(name)")
        #expect(result.exitCode == 64)
        for topic in GuideTopic.allCases {
            #expect(result.output.contains(topic.rawValue))
        }
        #expect(!result.output.contains("# Offsider"))
    }

    @Test("the skill and its topics use no em dashes")
    func noEmDashes() throws {
        for document in try Self.allDocuments() {
            #expect(!document.text.contains("\u{2014}"), "\(document.name) contains an em dash")
        }
    }

    @Test("every flag the skill and its topics name exists on that command")
    func documentedFlagsExist() async throws {
        let dump = try await TestHelpers.runOffsiderCommandSeparated("--experimental-dump-help").stdout
        let root = try JSONDecoder().decode(ToolInfo.self, from: Data(dump.utf8)).command
        var flags: [String: Set<String>] = [:]
        var everyFlag: Set<String> = []
        func collect(_ command: HelpCommand, path: [String]) -> Set<String> {
            var own = Set((command.arguments ?? []).flatMap { $0.names ?? [] }.filter { $0.kind == "long" }.map { "--" + $0.name })
            for sub in command.subcommands ?? [] {
                own.formUnion(collect(sub, path: path + [sub.commandName]))
            }
            if !path.isEmpty { flags[path.joined(separator: " ")] = own }
            everyFlag.formUnion(own)
            return own
        }
        _ = collect(root, path: [])

        for document in try Self.allDocuments() {
            for span in Self.codeSpans(in: document.text) {
                var words = span.split(whereSeparator: \.isWhitespace).map(String.init)
                if let index = words.firstIndex(where: { $0.hasSuffix("offsider") }) { words.removeFirst(index + 1) }
                let path = words.count > 1 && flags["\(words[0]) \(words[1])"] != nil ? "\(words[0]) \(words[1])" : words.first ?? ""
                let allowed = flags[path] ?? everyFlag
                for match in span.matches(of: #/(?:^|[^\w-])(--[a-z][a-z0-9-]*)/#) {
                    let flag = String(match.output.1)
                    #expect(allowed.contains(flag), "\(document.name): \(flag) is not an option of '\(flags[path] == nil ? "any command" : path)' in `\(span)`")
                }
            }
        }
    }

    /// Inline code spans and fenced code lines, with each single-quoted part (such as a batch step) as its own span.
    static func codeSpans(in text: String) -> [String] {
        var spans: [String] = []
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { fenced.toggle(); continue }
            let raw = fenced ? [line] : line.matches(of: #/`([^`]+)`/#).map { String($0.output.1) }
            for span in raw {
                let parts = span.components(separatedBy: "'")
                spans.append(parts.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).joined(separator: " "))
                spans += parts.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
            }
        }
        return spans
    }
}

private struct ToolInfo: Decodable {
    let command: HelpCommand
}

private struct HelpCommand: Decodable {
    let commandName: String
    let arguments: [HelpArgument]?
    let subcommands: [HelpCommand]?
}

private struct HelpArgument: Decodable {
    let names: [HelpName]?
}

private struct HelpName: Decodable {
    let kind: String
    let name: String
}
