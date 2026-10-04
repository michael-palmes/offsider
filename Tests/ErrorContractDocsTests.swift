import Foundation
import OffsiderCore
import Testing

@Suite("Error contract docs")
struct ErrorContractDocsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func section(_ heading: String, in file: String) throws -> [String] {
        let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: heading))
        let body = lines[(start + 1)...].prefix { !$0.hasPrefix("#") }
        return body.filter { $0.hasPrefix("| ") && !$0.hasPrefix("| ---") }.dropFirst().map { $0 }
    }

    private static func cells(_ row: String) -> [String] {
        row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test("the README exit code table matches the source")
    func exitCodeTable() throws {
        let documented = try Self.section("### Exit codes", in: "README.md").compactMap { Int32(Self.cells($0)[0]) }
        #expect(documented == OffsiderExitCode.allCases.map(\.rawValue))
    }

    @Test("the README reason table lists every reason with its exit code, and nothing else")
    func reasonTable() throws {
        var documented: [String: Int32] = [:]
        for row in try Self.section("### Error reasons", in: "README.md") {
            let cells = Self.cells(row)
            let reason = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            #expect(documented[reason] == nil, "\(reason) is listed twice")
            documented[reason] = Int32(cells[1])
        }
        let source = Dictionary(uniqueKeysWithValues: FailureReason.allCases.map { ($0.rawValue, $0.exitCode.rawValue) })
        #expect(documented == source)
    }

    @Test("the bundled skill explains every non-zero exit code")
    func skillExplainsCodes() throws {
        let skill = try String(contentsOf: Self.root.appendingPathComponent("Sources/Offsider/Resources/skills/offsider/SKILL.md"), encoding: .utf8)
        let block = try #require(skill.components(separatedBy: "\n").first { $0.hasPrefix("Exit codes: ") })
        for code in OffsiderExitCode.allCases where ![.success, .doctorWarnings, .doctorFailures].contains(code) {
            #expect(block.range(of: "(^|[ ;:])\(code.rawValue) ", options: .regularExpression) != nil, "SKILL.md does not explain exit \(code.rawValue)")
        }
        #expect(skill.contains("3 means warnings and 4 means failures"))
    }
}
