import Foundation
import Testing

/// Commands write through `Console`; each file's remaining raw writes are budgeted, and a budget only shrinks.
@Suite("Output discipline lint")
struct OutputDisciplineLintTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    static let patterns = [#"(^|[^\w.])print\("#, #"FileHandle\.standard(Output|Error)\.write"#, #"&standardError"#, #"fputs\("#]

    /// Raw writes each file may still make.
    static let budgets: [String: Int] = [
        "AndroidSession.swift": 1,
        "DeviceSession.swift": 2,
    ]

    static func code(_ url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    static func counts() throws -> [String: Int] {
        let commands = Self.sources.appendingPathComponent("Offsider/Commands")
        let files = try FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            + [Self.sources.appendingPathComponent("Offsider/main.swift")]
        let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
        var counts: [String: Int] = [:]
        for file in files {
            let count = try code(file).reduce(0) { total, line in
                total + expressions.reduce(0) { $0 + $1.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) }
            }
            if count > 0 { counts[file.lastPathComponent] = count }
        }
        return counts
    }

    @Test("no command writes raw output beyond its budget; new output goes through Console")
    func withinBudget() throws {
        for (file, count) in try Self.counts().sorted(by: { $0.key < $1.key }) {
            let budget = Self.budgets[file] ?? 0
            #expect(count <= budget, "\(file) makes \(count) raw writes, over its budget of \(budget): use Console.current")
        }
    }

    @Test("no budget is larger than the file needs")
    func noStaleBudgets() throws {
        let counts = try Self.counts()
        for (file, budget) in Self.budgets {
            #expect(counts[file, default: 0] == budget, "lower \(file)'s budget to \(counts[file, default: 0])")
        }
    }

    @Test("only the prompt and the presence check open /dev/tty")
    func devTTY() throws {
        let allowed: Set = ["Offsider/Utilities/TerminalPrompt.swift", "Offsider/Utilities/PersonPresence.swift"]
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.sources.path.count + 1))
            if try Self.code(url).contains(where: { $0.contains("\"/dev/tty\"") }), !allowed.contains(relative) { offenders.append(relative) }
        }
        #expect(offenders.isEmpty, "Write through Console instead: \(offenders.joined(separator: ", "))")
    }
}
