import Foundation
@testable import Offsider
import OffsiderCore
import Testing

@Suite("Screen goldens")
struct ScreenGoldenTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let path: String
        let listing: String
        let out: Console.Channel
        let err: Console.Channel

        var testDescription: String { path }
    }

    static let colour = TerminalStyle(colours: true)
    static let ascii = TerminalStyle(colours: false, ascii: true)

    static let cases: [Case] = [
        Case(path: "devices/mixed.person@44.txt", listing: "mixed", out: .person(columns: 44), err: .person(columns: 44)),
        Case(path: "devices/mixed.person@80.txt", listing: "mixed", out: .person(), err: .person()),
        Case(path: "devices/mixed.person@120.txt", listing: "mixed", out: .person(columns: 120), err: .person(columns: 120)),
        Case(path: "devices/mixed.person-ascii@80.txt", listing: "mixed", out: .person(style: ascii), err: .person(style: ascii)),
        Case(path: "devices/mixed.person-colour@80.txt", listing: "mixed", out: .person(style: colour), err: .person(style: colour)),
        Case(path: "devices/mixed.agent.txt", listing: "mixed", out: .agent, err: .agent),
        Case(path: "devices/empty.person@80.txt", listing: "empty", out: .person(), err: .person()),
        Case(path: "devices/empty.agent.txt", listing: "empty", out: .agent, err: .agent),
        Case(path: "start/start.person@80.txt", listing: "start", out: .person(), err: .person()),
        Case(path: "start/start.agent.txt", listing: "start", out: .agent, err: .agent),
    ]

    @Test("each screen renders as its golden", arguments: cases)
    func screen(_ golden: Case) throws {
        let capture = ConsoleCapture()
        let page = switch golden.listing {
        case "mixed": ScreenFixtures.page(ScreenFixtures.mixed)
        case "empty": ScreenFixtures.page(ScreenFixtures.empty)
        default: StartScreen.page(version: "0.13.0")
        }
        capture.console(out: golden.out, err: golden.err).show(page)
        try ScreenGoldens.check(golden.path, ScreenGoldens.text(capture))
    }

    static let message = "No simulator or AVD is named Pixel_10. Run `offsider devices` to see AVD names, then `offsider boot <AVD>`."

    @Test("an error reads as its golden for a person and for an agent")
    func error() throws {
        let person = PersonRenderer.error(Self.message, hint: "offsider devices --platform android", canvas: Canvas(columns: 80, style: .plain))
        try ScreenGoldens.check("error/error.person@80.txt", "#stderr\n" + person)
        let agent = ErrorReporter.errorText(Self.message) + ErrorReporter.hintText("offsider devices --platform android", message: Self.message, style: .plain)
        try ScreenGoldens.check("error/error.agent.txt", "#stderr\n" + agent)
    }

    @Test("a golden holds no device ID, home path or user name from this Mac")
    func noLeaks() throws {
        let files = (FileManager.default.enumerator(at: ScreenGoldens.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "txt" }
        #expect(files.count == Self.cases.count + 2)
        let user = NSUserName()
        for file in files {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!text.contains(NSHomeDirectory()) && !text.contains("/Users/" + user), "\(file.lastPathComponent) holds a home path")
            let ids = text.matches(of: #/[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/#).map { String($0.output) }
            #expect(ids.allSatisfy { $0.hasPrefix("00000000-0000-4000-8000-") }, "\(file.lastPathComponent) holds a real UDID")
        }
    }
}
