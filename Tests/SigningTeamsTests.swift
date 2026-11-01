@testable import Offsider
import OffsiderCore
import Testing

@Suite("Signing teams")
struct SigningTeamsTests {
    @Test("a code-signing certificate's subject names its team by the organisational unit and organisation")
    func readsSubject() {
        #expect(SigningTeams.team(commonName: "Apple Development: Jane Citizen (PERSON1234)", organisationalUnit: "ABCDE12345", organisation: "Example Pty Ltd")
            == SigningTeam(id: "ABCDE12345", name: "Example Pty Ltd"))
        #expect(SigningTeams.team(commonName: "Developer ID Application: Example Pty Ltd (ABCDE12345)", organisationalUnit: nil, organisation: nil)
            == SigningTeam(id: "ABCDE12345", name: "Example Pty Ltd"))
    }

    @Test("other certificates, a development certificate without a team, and a malformed team are skipped")
    func skipsOthers() {
        #expect(SigningTeams.team(commonName: "Mac Installer Distribution: Example (ABCDE12345)", organisationalUnit: "ABCDE12345", organisation: "Example") == nil)
        #expect(SigningTeams.team(commonName: "Apple Development: Jane Citizen (PERSON1234)", organisationalUnit: nil, organisation: nil) == nil)
        #expect(SigningTeams.team(commonName: "Apple Distribution: Example", organisationalUnit: "SHORT", organisation: "Example") == nil)
        #expect(SigningTeams.team(commonName: nil, organisationalUnit: "ABCDE12345", organisation: "Example") == nil)
    }

    @Test("several certificates for one team list it once, teams sorted by name")
    func dedupesAndSorts() {
        let teams = SigningTeams.teams([
            (commonName: "Apple Development: Jane Citizen (PERSON1234)", organisationalUnit: "ZZZZZ99999", organisation: "Zebra Labs"),
            (commonName: "Apple Distribution: Acme (ABCDE12345)", organisationalUnit: "ABCDE12345", organisation: "Acme"),
            (commonName: "iPhone Developer: Jane Citizen (PERSON1234)", organisationalUnit: "ZZZZZ99999", organisation: "Zebra Labs"),
        ])
        #expect(teams.map(\.label) == ["Acme (ABCDE12345)", "Zebra Labs (ZZZZZ99999)"])
    }

    @Test("a development certificate's email tells two teams with one name apart, on its row and its receipt")
    func collidingNames() throws {
        let teams = SigningTeams.teams([
            (commonName: "Apple Development: jane@example.com (PERSON1234)", organisationalUnit: "AAAAA11111", organisation: "Jane Citizen"),
            (commonName: "Apple Development: Jane Citizen (PERSON5678)", organisationalUnit: "BBBBB22222", organisation: "Jane Citizen"),
            (commonName: "Apple Development: Jane Citizen (PERSON9012)", organisationalUnit: "CCCCC33333", organisation: "Jane Citizen"),
            (commonName: "Apple Development: Jane Citizen (PERSON9012)", organisationalUnit: "DDDDD44444", organisation: "Example Pty Ltd"),
        ])
        #expect(DeviceAccessAllow.teamRows(teams).map(\.columns) == [
            ["Example Pty Ltd", "DDDDD44444"],
            ["Jane Citizen", "AAAAA11111  jane@example.com"],
            ["Jane Citizen", "BBBBB22222"],
            ["Jane Citizen", "CCCCC33333"],
        ])
        let long = String(repeating: "x", count: 55)
        let twins = [SigningTeam(id: "AAAAA11111", name: long, account: "jane@example.com"), SigningTeam(id: "BBBBB22222", name: long)]
        #expect(DeviceAccessAllow.teamShown(twins[0], among: twins).hasSuffix("(jane@example.com)"))
        #expect(teams.map { $0.shown(among: teams) } == ["Example Pty Ltd", "Jane Citizen (jane@example.com)", "Jane Citizen (BBBBB22222)", "Jane Citizen (CCCCC33333)"])
    }

    @Test("the email comes from a development certificate's holder, and from any of a team's certificates")
    func whichEmail() {
        let team = { (commonName: String) in SigningTeams.team(commonName: commonName, organisationalUnit: "ABCDE12345", organisation: "Jane Citizen")?.account }
        #expect(team("Apple Development: jane@example.com (PERSON1234)") == "jane@example.com")
        #expect(team("iPhone Developer: jane@example.com (PERSON1234)") == "jane@example.com")
        #expect(team("Apple Distribution: jane@example.com (ABCDE12345)") == nil)
        #expect(team("Developer ID Application: jane@example.com (ABCDE12345)") == nil)
        #expect(team("Apple Development: Jane Citizen (PERSON1234)") == nil)
        #expect(team("Apple Development: not an@email (PERSON1234)") == nil)

        let nameless = SigningTeams.team(commonName: "Apple Development: jane@example.com (PERSON1234)", organisationalUnit: "ABCDE12345", organisation: nil)
        #expect(nameless == SigningTeam(id: "ABCDE12345", name: "jane@example.com"))

        let merged = SigningTeams.teams([
            (commonName: "Apple Distribution: Jane Citizen (ABCDE12345)", organisationalUnit: "ABCDE12345", organisation: "Jane Citizen"),
            (commonName: "Apple Development: jo@example.com (PERSON5678)", organisationalUnit: "ABCDE12345", organisation: "Jane Citizen"),
            (commonName: "Apple Development: jane@example.com (PERSON1234)", organisationalUnit: "ABCDE12345", organisation: "Jane Citizen"),
        ])
        #expect(merged == [SigningTeam(id: "ABCDE12345", name: "Jane Citizen", account: "jane@example.com")])
    }

    @Test("a certificate's email cannot draw on the terminal or run long")
    func emailIsCleaned() throws {
        let forged = "jane\u{1B}]52;c;eA==\u{07}\u{202E}@" + String(repeating: "x", count: 500) + ".example.com"
        let team = try #require(SigningTeams.team(commonName: "Apple Development: \(forged) (PERSON1234)", organisationalUnit: "ABCDE12345", organisation: "Jane Citizen"))
        let cell = try #require(DeviceAccessAllow.teamRows([team]).first?.columns.last)
        #expect(!cell.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{07}" || $0 == "\u{202E}" })
        #expect(cell.count < 100)
        #expect(!PromptScreen.label(team.shown(among: [team, SigningTeam(id: "BBBBB22222", name: "Jane Citizen")])).unicodeScalars.contains("\u{1B}"))
    }
}
