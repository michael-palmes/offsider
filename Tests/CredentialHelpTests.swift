import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("credential help")
struct CredentialHelpTests {
    /// The `--about`, `--avoid` or `--state` row of `credential --help`, which a page this wide keeps on one line.
    static func helpRow(_ flag: String) throws -> String {
        let help = CredentialCommand.helpMessage(columns: 10_000)
        let line = try #require(help.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(flag) <text>") })
        return String(line)
    }

    static func parses(_ flag: String, _ value: String) -> Bool {
        (try? CredentialCommand.parse(["describe", "dev", flag, value, "--app", "com.example.app"])) != nil
    }

    @Test("each note's help names the limit the parser enforces: its length, one line, no email address", arguments: LoginNote.allCases.map(\.flag))
    func helpMatchesParser(_ flag: String) throws {
        let row = try Self.helpRow(flag)
        let match = try #require(row.firstMatch(of: #/at most (\d+) characters/#), "\(flag) help names no length: \(row)")
        let limit = try #require(Int(match.1))
        #expect(Self.parses(flag, String(repeating: "a", count: limit)), "\(flag) refuses the \(limit) characters its help allows")
        #expect(!Self.parses(flag, String(repeating: "a", count: limit + 1)), "\(flag) takes more than the \(limit) its help says")

        #expect(row.contains("One line"))
        #expect(!Self.parses(flag, "Admin\non staging"))
        #expect(row.contains("no email address"))
        #expect(!Self.parses(flag, "Signs in as qa@example.com"))
    }

    @Test("describe with no flag names every flag the help says goes with describe")
    func describeNamesEveryFlag() throws {
        let lines = CredentialCommand.helpMessage(columns: 10_000).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var flags: [String] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("--") {
            let parts = line.components(separatedBy: "  ").filter { !$0.isEmpty }
            let text = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : (lines.indices.contains(index + 1) ? lines[index + 1] : "")
            guard text.hasPrefix("With add or describe") else { continue }
            flags += parts[0].split(separator: " ")[0].split(separator: "/").map(String.init)
        }
        #expect(flags.contains("--confirm-always") && flags.contains("--no-confirm-always"))
        do {
            _ = try CredentialCommand.parse(["describe", "dev", "--app", "com.example.app"])
            Issue.record("describe parsed with no flag")
        } catch {
            let message = CredentialCommand.message(for: error)
            for flag in flags { #expect(message.contains("\(flag),") || message.contains("\(flag) ") || message.hasSuffix("\(flag)."), "describe's message leaves out \(flag)") }
        }
    }
}
