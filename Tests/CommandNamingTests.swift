import Foundation
import Testing

@Suite("Command Naming Tests")
struct CommandNamingTests {
    private static let upstreamName = #"\baxe\b"#

    @Test("root help presents the offsider command")
    func rootHelpUsesOffsiderName() async throws {
        let help = try await TestHelpers.runOffsiderCommand("--help").output

        #expect(help.contains("USAGE: offsider <subcommand>"))
        #expect(!mentionsUpstreamName(help))
    }

    @Test("every listed subcommand presents the offsider command")
    func subcommandHelpUsesOffsiderName() async throws {
        let rootHelp = try await TestHelpers.runOffsiderCommand("--help").output
        let subcommands = TestHelpers.listedSubcommands(in: rootHelp)

        #expect(subcommands.contains("tap"))
        #expect(subcommands.contains("init"))
        #expect(subcommands.contains("guide"))
        #expect(subcommands.contains("boot"))

        for name in subcommands {
            let help = try await TestHelpers.runOffsiderCommand("\(name) --help").output
            #expect(
                help.range(of: "USAGE: offsider \(name)(\\s|$)", options: .regularExpression) != nil,
                "\(name) --help does not show offsider usage"
            )
            #expect(!mentionsUpstreamName(help), "\(name) --help mentions the upstream name")
        }
    }

    private func mentionsUpstreamName(_ text: String) -> Bool {
        text.range(of: Self.upstreamName, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
