import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Init screen")
struct InitScreenTests {
    static let unicode = TerminalStyle(colours: false)

    @Test("init's results on a terminal: a bold tick line per client with its path dim under it, and the next command")
    func initResults() {
        let lines = ["Installed Offsider skill -> Claude Code: /Users/me/.claude/skills/offsider/SKILL.md", "Next: offsider doctor"]
        #expect(InitScreen.styled(lines, style: Self.unicode) == [
            "✅ Installed Offsider skill for Claude Code", "   /Users/me/.claude/skills/offsider/SKILL.md", "   Next  offsider doctor",
        ])
        #expect(InitScreen.styled(["No installed Offsider skill directories were found."], style: Self.unicode) == ["No installed Offsider skill directories were found."])
    }
}
