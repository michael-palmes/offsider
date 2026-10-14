@testable import Offsider
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
}
