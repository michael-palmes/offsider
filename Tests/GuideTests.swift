import ArgumentParser
import Foundation
import OffsiderCore
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

    /// Every command path `--help` lists, nested ones included, in registration order.
    static func displayedCommandPaths(_ commands: [any ParsableCommand.Type] = OffsiderCommand.configuration.subcommands, prefix: [String] = []) -> [String] {
        commands.filter { $0.configuration.shouldDisplay }.flatMap { command -> [String] in
            let path = prefix + [command._commandName]
            let children = command.configuration.subcommands
            return children.isEmpty ? [path.joined(separator: " ")] : displayedCommandPaths(children, prefix: path)
        }
    }

    @Test("every command is in the skill's Commands paragraph and the README's Commands table, by itself or a parent")
    func everyCommandIsDocumented() throws {
        let skillLines = try Self.read("SKILL.md").components(separatedBy: "\n")
        let paragraph = skillLines.drop { $0 != "## Commands" }.dropFirst().first { !$0.isEmpty } ?? ""
        let skillNames = Set(paragraph.matches(of: #/`([^`]+)`/#).map { String($0.output.1) })

        let readme = try String(contentsOf: ErrorContractDocsTests.root.appendingPathComponent("README.md"), encoding: .utf8)
        let readmeLines = readme.components(separatedBy: "\n").drop { $0 != "## Commands" }.dropFirst().prefix { !$0.hasPrefix("## ") }
        let readmeNames = Set(readmeLines.filter { $0.hasPrefix("| `") }.compactMap { row in
            row.split(separator: "|").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " `")) }
        })

        let paths = Self.displayedCommandPaths()
        #expect(paths.contains("run start"))
        for path in paths {
            let words = path.split(separator: " ")
            let names = Set(words.indices.map { words[...$0].joined(separator: " ") })
            #expect(!skillNames.isDisjoint(with: names), "SKILL.md ## Commands does not name \(path)")
            #expect(!readmeNames.isDisjoint(with: names), "README ## Commands does not list \(path)")
        }
    }

    // MARK: - Project guide

    /// A temp tree: `outer/OFFSIDER.md` above `outer/repo/app/src`, with `repo` holding `.git` when `git` is set.
    private static func projectTree(git: GitMarker?, guideIn: String?) throws -> (root: String, src: String) {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-guide-\(UUID().uuidString)")
        let src = root + "/outer/repo/app/src"
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        switch git {
        case .directory: try FileManager.default.createDirectory(atPath: root + "/outer/repo/.git", withIntermediateDirectories: true)
        case .worktreeFile: try Data("gitdir: /elsewhere\n".utf8).write(to: URL(fileURLWithPath: root + "/outer/repo/.git"))
        case nil: break
        }
        if let guideIn {
            try Data("# Recipes\nLog in with the test account.\n".utf8).write(to: URL(fileURLWithPath: root + "/" + guideIn + "/OFFSIDER.md"))
        }
        return (root, src)
    }

    private enum GitMarker { case directory, worktreeFile }

    @Test("the project guide is found in a parent directory")
    func projectGuideInParent() throws {
        let tree = try Self.projectTree(git: .directory, guideIn: "outer/repo")
        defer { try? FileManager.default.removeItem(atPath: tree.root) }
        let found = try ProjectGuide.locate(from: tree.src + "/", home: "/nonexistent")
        #expect(found.path.hasSuffix("/outer/repo/OFFSIDER.md"))
        #expect(found.text.contains("test account"))
    }

    @Test("the search stops at the repository root, a .git directory or a worktree's .git file", arguments: [true, false])
    func projectGuideStopsAtRepository(directory: Bool) throws {
        let tree = try Self.projectTree(git: directory ? .directory : .worktreeFile, guideIn: "outer")
        defer { try? FileManager.default.removeItem(atPath: tree.root) }
        #expect(throws: ProjectGuide.Failure.self) { try ProjectGuide.locate(from: tree.src, home: "/nonexistent") }
        #expect { try Guide.projectGuide(from: tree.src, home: "/nonexistent") } throws: { error in
            "\(error)".contains("No OFFSIDER.md in") && "\(error)".contains("/outer/repo.") && "\(error)".contains("Add one")
        }
    }

    @Test("a project guide over 256 KiB is refused")
    func projectGuideTooLarge() throws {
        let tree = try Self.projectTree(git: .directory, guideIn: nil)
        defer { try? FileManager.default.removeItem(atPath: tree.root) }
        try Data(repeating: 0x61, count: 256 * 1024 + 1).write(to: URL(fileURLWithPath: tree.src + "/OFFSIDER.md"))
        #expect { try ProjectGuide.locate(from: tree.src, home: "/nonexistent") } throws: { "\($0)".contains("256 KiB") }
    }

    @Test("--project with a topic, or a missing path, is a usage error")
    func projectGuideUsage() async throws {
        #expect(try await TestHelpers.runOffsiderCommandAllowFailure("guide selectors --project .").exitCode == 64)
        #expect(try await TestHelpers.runOffsiderCommandAllowFailure("guide --project /nonexistent/offsider").exitCode == 64)
    }

    @Test("guide --project prints the file, and plain guide names it only when there is one")
    func projectGuideFromBinary() async throws {
        let tree = try Self.projectTree(git: .directory, guideIn: "outer/repo")
        defer { try? FileManager.default.removeItem(atPath: tree.root) }
        let binary = try TestHelpers.getOffsiderPath()

        let printed = try await CommandRunner.runSeparated("cd '\(tree.src)' && '\(binary)' guide --project .")
        #expect(printed.exitCode == 0)
        #expect(printed.stdout == "# Recipes\nLog in with the test account.\n")
        #expect(printed.stderr.contains("Project guide: ") && printed.stderr.contains("/outer/repo/OFFSIDER.md"))

        let listed = try await CommandRunner.runSeparated("cd '\(tree.src)' && '\(binary)' guide")
        #expect(listed.stdout.contains("/outer/repo/OFFSIDER.md (offsider guide --project .)"))
        try FileManager.default.removeItem(atPath: tree.root + "/outer/repo/OFFSIDER.md")
        let none = try await CommandRunner.runSeparated("cd '\(tree.src)' && '\(binary)' guide")
        #expect(!none.stdout.contains("Project guide"))
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
