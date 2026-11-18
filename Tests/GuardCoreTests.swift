import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("offsider.guard.json")
struct GuardConfigTests {
    private static func parse(_ text: String) throws -> GuardConfig {
        try GuardConfig.parse(Data(text.utf8), path: "/repo/offsider.guard.json")
    }

    private static func failure(_ text: String) -> String? {
        do {
            _ = try parse(text)
            return nil
        } catch {
            return "\(error)"
        }
    }

    static let example = """
    {
      "//": "Everything not listed is free.",
      "apps": ["com.mpalmes.offsider.playground", "com.mpalmes.offsider.playground.rn"],
      "askUsers": ["tester"],
      "ask": [
        { "name": "Place an order", "id": "order-confirm-button" },
        { "name": "Move funds", "label": "Transfer", "screen": { "id": "transfer-review" } }
      ],
      "never": [
        { "name": "Password", "screen": { "label": "Change password" }, "except": [{ "id": "face-id-switch" }] }
      ]
    }
    """

    @Test("every key parses, and the file writes back the same rules")
    func parsesAndRoundTrips() throws {
        let config = try Self.parse(Self.example)
        #expect(config.apps == ["com.mpalmes.offsider.playground", "com.mpalmes.offsider.playground.rn"])
        #expect(config.askUsers == ["tester"])
        #expect(config.rules(.ask).map(\.name) == ["Place an order", "Move funds"])
        #expect(config.rules(.never) == [
            GuardRule(name: "Password", action: .never, screen: GuardMatcher(label: "Change password"), except: [GuardMatcher(id: "face-id-switch")]),
        ])
        #expect(try GuardConfig.parse(config.encoded()) == config)
    }

    @Test("a file that would guard nothing, or guard by mistake, is refused with the place named", arguments: [
        ("{}", "apps must list"),
        (#"{"apps": ["com.example.app"]}"#, "at least one rule"),
        (#"{"apps": ["com.example.app"], "ask": [{"name": "Empty"}]}"#, "names no control and no screen"),
        (#"{"apps": ["com.example.app"], "ask": [{"name": "Typo", "lable": "Buy"}]}"#, "unknown key lable"),
        (#"{"apps": ["com.example.app"], "allow": []}"#, "unknown key allow"),
        (#"{"apps": ["com.example.app"], "ask": [{"name": "A", "id": "x"}], "never": [{"name": "A", "id": "y"}]}"#, "share a name"),
        (#"{"apps": ["com.example.app"], "ask": [{"name": "A", "id": "x", "except": [{"id": "y"}]}]}"#, "except lists the controls a whole-screen rule leaves free"),
        (#"{"apps": ["not an app id"], "ask": [{"name": "A", "id": "x"}]}"#, "not an app id"),
        (#"{"apps": ["com.example.app"], "ask": [{"name": "A", "id": ""}]}"#, "ask[0].id must be"),
    ])
    func refusesBadFiles(text: String, expected: String) {
        #expect(Self.failure(text)?.contains(expected) == true, "\(Self.failure(text) ?? "parsed")")
    }
}

@Suite("Guard verdicts")
struct GuardJudgeTests {
    static let order = GuardRule(name: "Place an order", action: .ask, control: GuardMatcher(id: "order-confirm"))
    static let transfer = GuardRule(name: "Move funds", action: .ask, control: GuardMatcher(label: "Transfer"), screen: GuardMatcher(id: "transfer-review"))
    static let password = GuardRule(name: "Password", action: .never, screen: GuardMatcher(label: "Change password"), except: [GuardMatcher(id: "face-id-switch")])

    static func button(_ id: String?, _ label: String?, y: Double) -> UINode {
        FakeUI.node(.button, id: id, label: label, frame: FakeUI.frame(20, y, 200, 44))
    }

    static func verdict(_ rules: [GuardRule], _ nodes: [UINode], _ input: GuardInput, textNear: ((UIPoint) -> [String]?)? = nil) -> GuardHit? {
        GuardJudge.verdict(rules: rules, tree: FakeUI.tree(nodes), input: input, textNear: textNear)
    }

    @Test("a coordinate that lands on a guarded control is caught, and one beside it is free")
    func coordinateTap() {
        let screen = [Self.button("order-confirm", "Buy now", y: 600), Self.button("order-cancel", "Cancel", y: 700)]
        let hit = Self.verdict([Self.order], screen, .press(UIPoint(x: 100, y: 620)))
        #expect(hit?.action == .ask)
        #expect(hit?.rule.name == "Place an order")
        #expect(hit?.control == "Buy now")
        #expect(Self.verdict([Self.order], screen, .press(UIPoint(x: 100, y: 720))) == nil)
        #expect(Self.verdict([Self.order], screen, .press(UIPoint(x: 100, y: 100))) == nil)
    }

    @Test("a full-screen sibling listed after the control, as iOS trees have, does not hide it from the guard")
    func laterSiblingDoesNotHideControl() {
        let screen = [Self.button("order-confirm", "Buy now", y: 600), FakeUI.node(.group, id: "page", frame: FakeUI.frame(0, 0, 402, 874))]
        #expect(Self.verdict([Self.order], screen, .press(UIPoint(x: 100, y: 620)))?.control == "Buy now")
        #expect(Self.verdict([Self.order], screen, .path(from: UIPoint(x: 100, y: 620), to: UIPoint(x: 100, y: 200)))?.action == .ask)
        #expect(Self.verdict([Self.order], screen, .press(UIPoint(x: 100, y: 200))) == nil)
    }

    @Test("a label inside a guarded parent is guarded too")
    func childOfGuardedControl() {
        let parent = FakeUI.node(.button, id: "order-confirm", frame: FakeUI.frame(20, 600, 200, 44), children: [
            FakeUI.node(.text, label: "Buy now", frame: FakeUI.frame(60, 610, 80, 20)),
        ])
        #expect(Self.verdict([Self.order], [parent], .press(UIPoint(x: 80, y: 620)))?.action == .ask)
    }

    @Test("a label matches whatever its case, quotes or spacing")
    func labelFolding() {
        let rule = GuardRule(name: "Delete", action: .never, control: GuardMatcher(label: "Yes, delete"))
        #expect(Self.verdict([rule], [Self.button(nil, "YES,  Delete", y: 300)], .press(UIPoint(x: 50, y: 310)))?.action == .never)
    }

    @Test("a rule scoped to a screen is quiet everywhere else")
    func screenScope() {
        let elsewhere = [Self.button("filter-apply", "Transfer", y: 300)]
        #expect(Self.verdict([Self.transfer], elsewhere, .press(UIPoint(x: 50, y: 310))) == nil)
        let review = elsewhere + [FakeUI.node(.header, id: "transfer-review", label: "Review", frame: FakeUI.frame(0, 60, 402, 40))]
        #expect(Self.verdict([Self.transfer], review, .press(UIPoint(x: 50, y: 310)))?.rule.name == "Move funds")
    }

    @Test("a whole-screen rule lets a swipe, a way out and its exceptions through, and nothing else")
    func lookOnlyScreen() {
        let screen = [
            FakeUI.node(.header, label: "Change password", frame: FakeUI.frame(0, 60, 402, 40)),
            Self.button("save", "Save", y: 300),
            Self.button(nil, "Cancel", y: 400),
            FakeUI.node(.switch, id: "face-id-switch", label: "Face ID", frame: FakeUI.frame(20, 500, 200, 44)),
        ]
        #expect(Self.verdict([Self.password], screen, .press(UIPoint(x: 50, y: 310)))?.action == .never)
        #expect(Self.verdict([Self.password], screen, .press(UIPoint(x: 300, y: 800)))?.action == .never)
        #expect(Self.verdict([Self.password], screen, .press(UIPoint(x: 50, y: 410))) == nil)
        #expect(Self.verdict([Self.password], screen, .press(UIPoint(x: 50, y: 510))) == nil)
        #expect(Self.verdict([Self.password], screen, .path(from: UIPoint(x: 200, y: 700), to: UIPoint(x: 200, y: 200))) == nil)
        #expect(Self.verdict([Self.password], screen, .activate)?.action == .never)
    }

    @Test("never wins when two rules cover one control")
    func strictestWins() {
        let never = GuardRule(name: "Withdraw", action: .never, control: GuardMatcher(labelContains: "buy"))
        let hit = Self.verdict([Self.order, never], [Self.button("order-confirm", "Buy now", y: 600)], .press(UIPoint(x: 100, y: 620)))
        #expect(hit?.action == .never)
        #expect(hit?.rule.name == "Withdraw")
    }

    @Test("Return is guarded while a guarded control is on screen, and free otherwise")
    func activate() {
        #expect(Self.verdict([Self.order], [Self.button("order-confirm", "Buy now", y: 600)], .activate)?.control == "Buy now")
        #expect(Self.verdict([Self.order], [Self.button("search", "Search", y: 600)], .activate) == nil)
        #expect(Self.verdict([Self.order], [Self.button("order-confirm", "Buy now", y: 2000)], .activate) == nil)
    }

    @Test("a drag that starts on a guarded control is caught")
    func dragFromControl() {
        let slide = [FakeUI.node(.slider, id: "order-confirm", label: "Slide to buy", frame: FakeUI.frame(20, 600, 360, 60))]
        #expect(Self.verdict([Self.order], slide, .path(from: UIPoint(x: 40, y: 630), to: UIPoint(x: 360, y: 630)))?.action == .ask)
    }

    @Test("a tap the tree cannot explain on a guarded screen asks, unless the words there clear it")
    func blindTap() {
        let review = [FakeUI.node(.header, id: "transfer-review", label: "Review", frame: FakeUI.frame(0, 60, 402, 40))]
        let blind = UIPoint(x: 200, y: 700)
        let unsure = Self.verdict([Self.transfer], review, .press(blind))
        #expect(unsure?.unsure == true)
        #expect(unsure?.action == .ask)
        #expect(Self.verdict([Self.transfer], review, .press(blind), textNear: { _ in [] }) == nil)
        #expect(Self.verdict([Self.transfer], review, .press(blind), textNear: { _ in ["Share"] }) == nil)
        let read = Self.verdict([Self.transfer], review, .press(blind), textNear: { _ in ["transfer"] })
        #expect(read?.unsure == false)
        #expect(read?.control == "transfer")
        let byID = GuardRule(name: "Confirm", action: .never, control: GuardMatcher(id: "confirm"), screen: GuardMatcher(id: "transfer-review"))
        #expect(Self.verdict([byID], review, .press(blind), textNear: { _ in ["Share"] })?.unsure == true)
        #expect(Self.verdict([Self.transfer], review, .path(from: blind, to: UIPoint(x: 200, y: 200))) == nil)
        #expect(Self.verdict([Self.order], [], .press(blind)) == nil)
    }
}

@Suite("Guard approvals")
struct GuardApprovalTests {
    static let app = "com.mpalmes.offsider.playground"
    static let order = GuardJudgeTests.order
    static let password = GuardJudgeTests.password
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func config(_ rules: [GuardRule], askUsers: [String]? = nil) -> GuardConfig {
        GuardConfig(apps: [app], rules: rules, askUsers: askUsers)
    }

    static func approval(_ rules: [GuardRule], askUsers: [String]? = nil) -> GuardApproval {
        GuardApproval(app: app, approved: now, rules: rules, askUsers: askUsers)
    }

    @Test("approvals survive the file they are kept in")
    func roundTrip() throws {
        let approvals = GuardApprovals().approving(Self.config([Self.order, Self.password], askUsers: ["tester"]), source: "/repo/offsider.guard.json", now: Self.now)
        #expect(try GuardApprovals.parse(approvals.encoded()) == approvals)
    }

    @Test("no rules anywhere is missing, a file alone is enforced but not ready")
    func states() {
        #expect(GuardSet.resolve(app: Self.app, approval: nil, file: nil, sealIntact: true).state == .missing)
        let unapproved = GuardSet.resolve(app: Self.app, approval: nil, file: Self.config([Self.order]), sealIntact: true)
        #expect(unapproved.state == .unapproved)
        #expect(unapproved.rules == [Self.order])
        #expect(!unapproved.isReady)
        #expect(GuardSet.resolve(app: Self.app, approval: Self.approval([Self.order]), file: nil, sealIntact: true).isReady)
        #expect(GuardSet.resolve(app: Self.app, approval: Self.approval([Self.order]), file: nil, sealIntact: false).state == .changed)
        let other = GuardConfig(apps: ["com.example.other"], rules: [Self.password])
        #expect(GuardSet.resolve(app: Self.app, approval: nil, file: other, sealIntact: true).state == .missing)
    }

    @Test("a file can tighten at once and never loosen what was approved")
    func stricterOfTwo() {
        let approved = Self.approval([Self.order, Self.password], askUsers: ["tester"])
        let emptied = GuardSet.resolve(app: Self.app, approval: approved, file: Self.config([Self.order], askUsers: ["tester", "owner"]), sealIntact: true)
        #expect(emptied.rules == [Self.order, Self.password])
        #expect(emptied.askUsers == ["tester"])
        #expect(emptied.loosened == ["Password: removed, still never", "askUsers: adds owner"])
        #expect(emptied.isReady)

        var softened = Self.password
        softened.action = .ask
        let weaker = GuardSet.resolve(app: Self.app, approval: approved, file: Self.config([Self.order, softened], askUsers: ["tester"]), sealIntact: true)
        #expect(weaker.rules.contains(Self.password))
        #expect(weaker.loosened == ["Password: changed, the approved rule still applies"])

        let extra = GuardRule(name: "Delete account", action: .never, control: GuardMatcher(id: "delete-account"))
        let tighter = GuardSet.resolve(app: Self.app, approval: approved, file: Self.config([Self.order, Self.password, extra], askUsers: []), sealIntact: true)
        #expect(tighter.added == [extra])
        #expect(tighter.rules.contains(extra))
        #expect(tighter.askUsers == [])
        #expect(tighter.loosened.isEmpty)
    }

    @Test("an ask is offered only for a saved login the rules allow")
    func askUsers() {
        let open = GuardSet(app: Self.app, state: .ready)
        #expect(open.mayAsk(user: "anyone"))
        #expect(!open.mayAsk(user: nil))
        let narrow = GuardSet(app: Self.app, state: .ready, askUsers: ["tester"])
        #expect(narrow.mayAsk(user: "tester"))
        #expect(!narrow.mayAsk(user: "owner"))
    }
}
