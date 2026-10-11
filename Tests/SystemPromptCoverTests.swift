import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A prompt another process draws over an iOS app, such as AutoFill's Save Password?, which the app's tree shows only as an empty host.
@Suite("System prompt cover")
@MainActor
struct SystemPromptCoverTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let appPID = 4100
    static let promptPID = 4200
    static let signOut = FakeUI.node(.button, id: "sign-out", label: "Sign out", frame: FakeUI.frame(16, 219, 370, 44), pid: appPID)

    static func group(_ frame: UIFrame, _ children: [UINode] = []) -> UINode {
        FakeUI.node(.group, frame: frame, pid: appPID, children: children)
    }

    static let screen = FakeUI.frame(0, 0, 402, 874)

    /// The app's window, the window the keyboard leaves behind, and with `prompt` the empty host of the other process's view, larger than the screen.
    static func signedIn(prompt: Bool, keyboard: Bool = false) -> UITree {
        var leftover = [group(screen, [group(screen)])]
        if prompt {
            leftover.append(group(screen, [group(screen, [group(screen, [group(FakeUI.frame(0, 0, 804, 1748))])])]))
        }
        var windows = [
            group(screen, [
                FakeUI.node(.text, id: "session", label: "Signed in", frame: FakeUI.frame(16, 122, 370, 20), pid: appPID),
                signOut,
            ]),
            group(screen, leftover),
        ]
        if keyboard {
            windows.append(group(screen, [group(FakeUI.frame(0, -54, 402, 1244), [
                FakeUI.node(.keyboard, id: "UIKeyboardLayoutStar Preview", frame: FakeUI.frame(0, 590, 402, 226), pid: appPID),
            ])]))
        }
        let root = FakeUI.node(.application, label: "Playground", frame: screen, pid: appPID, children: windows)
        return UITree(platform: .ios, device: device.rawValue, roots: [root])
    }

    static let backdrop = FakeUI.node(.group, frame: screen, pid: promptPID)
    static let title = FakeUI.node(.text, label: "Save Password?", frame: FakeUI.frame(71, 420, 260, 40), pid: promptPID)
    static let save = FakeUI.node(.button, label: "Save", frame: FakeUI.frame(205, 523, 140, 48), pid: promptPID)

    /// A simulator showing the prompt: its title at the middle of the screen, its Save button, and its backdrop everywhere else.
    static func prompting(_ trees: [UITree]) -> HitTestingFakeBackend {
        let backend = HitTestingFakeBackend(trees: trees)
        backend.processNames = [promptPID: "SafariViewService"]
        backend.hits = { point in
            if title.frame?.contains(point) == true { return title }
            if save.frame?.contains(point) == true { return save }
            return backdrop
        }
        return backend
    }

    private static func tap(_ arguments: [String], on backend: FakeDeviceBackend) async throws {
        try await Tap.parse(arguments + ["--no-settle", "--device", device.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
    }

    private static func describe(_ arguments: [String], on backend: FakeDeviceBackend) async throws -> String {
        defer { DeviceActivityLedger.current.reset() }
        return try await DescribeUI.parse(arguments + ["--device", device.rawValue]).describe(on: DeviceRouter.Route(backend: backend, device: device))
    }

    @Test("an empty window over the app holding a container larger than the screen is a prompt's host; the keyboard's leftovers and the keyboard are not")
    func hostShape() {
        #expect(SystemPrompt.hosts(in: Self.signedIn(prompt: true)).map(\.index) == [1])
        #expect(SystemPrompt.hasHost(over: Self.signOut, in: Self.signedIn(prompt: true)))
        #expect(SystemPrompt.hosts(in: Self.signedIn(prompt: false)).isEmpty)
        #expect(SystemPrompt.hosts(in: Self.signedIn(prompt: false, keyboard: true)).isEmpty)
        #expect(!SystemPrompt.hasHost(over: Self.signOut, in: Self.signedIn(prompt: false, keyboard: true)))

        var android = Self.signedIn(prompt: true)
        android.platform = .android
        #expect(SystemPrompt.hosts(in: android).isEmpty)
    }

    @Test("a hit is foreign only when its pid is one no node of the tree carries")
    func foreignHit() {
        let roots = Self.signedIn(prompt: true).roots
        #expect(SystemPrompt.isForeign(Self.backdrop, in: roots))
        #expect(!SystemPrompt.isForeign(Self.group(Self.screen), in: roots))
        #expect(!SystemPrompt.isForeign(FakeUI.node(.group, frame: Self.screen), in: roots))
        #expect(!SystemPrompt.isForeign(Self.backdrop, in: FakeUI.tree([FakeUI.node(.button, id: "b", frame: Self.screen)]).roots))
    }

    @Test("with a prompt's host, the cover judge refuses a hit from another process and still passes the app's own empty group; without one it judges that hit as before")
    func judgeForeignHit() throws {
        let tree = Self.signedIn(prompt: true)
        let viewport = try #require(tree.viewport)
        func judge(_ hit: UINode, host: Bool = true) -> CoverVerdict? {
            CoverJudge.judge(
                target: Self.signOut, matched: Self.signOut, point: UIPoint(x: 201, y: 241), candidates: [], roots: tree.roots,
                viewport: viewport, stack: ScreenStack.build(roots: tree.roots, viewport: viewport), hit: hit, otherProcessCovers: host
            )
        }
        let verdict = try #require(judge(Self.backdrop))
        #expect(verdict.evidence == .otherProcess && verdict.isConfident)
        #expect(verdict.cover == Self.backdrop)
        #expect(judge(Self.group(Self.screen)) == nil)
        #expect(judge(Self.backdrop, host: false) == nil)
    }

    @Test("tap under the prompt's backdrop refuses with target_covered, names the prompt and its process, offers the backdrop tap and sends nothing")
    func tapUnderBackdropRefuses() async {
        let backend = Self.prompting([Self.signedIn(prompt: true)])

        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "sign-out"], on: backend)
        }

        #expect(error?.reason == .targetCovered)
        #expect(error?.userFacingDescription == "--id 'sign-out' at (201, 241) is under the system prompt 'Save Password?' from SafariViewService, so the tap would land on its backdrop and only dismiss it. Nothing was sent. Answer the prompt (its buttons are not in describe-ui, so take a screenshot to find them) or dismiss it with a tap on its backdrop (`offsider tap -x 201 -y 241 --device fake-device`), then retry; or pass --allow-covered to tap anyway.")
        #expect(error?.coveredBy == CoverReport(role: "group", id: nil, label: nil, frame: Self.screen, screen: "Save Password?", evidence: .otherProcess, process: "SafariViewService"))
        #expect(error?.hint == "offsider screenshot --device fake-device")
        #expect(backend.hitAppPIDs == [[Self.appPID], [Self.appPID]], "each read must take another process's empty backdrop as its answer")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("without a prompt's host, a hit from another process, such as the status bar, is judged as before: a guessed cover warns and taps")
    func foreignHitWithoutHost() async throws {
        let banner = FakeUI.node(.text, id: "banner", label: "Banner", frame: FakeUI.frame(0, 200, 402, 80), pid: Self.appPID)
        var tree = Self.signedIn(prompt: false)
        tree.roots[0].children[0].children.append(banner)
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { _ in FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 54), pid: Self.promptPID) }

        try await Self.tap(["--id", "sign-out"], on: backend)

        #expect(backend.hitTests == 1)
        #expect(backend.hitAppPIDs == [[]])
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 241))])
    }

    @Test("tap whose point falls on one of the prompt's controls names that control and offers no backdrop tap")
    func tapUnderControlRefuses() async {
        let under = FakeUI.node(.button, id: "under-save", label: "Under", frame: FakeUI.frame(205, 523, 140, 48), pid: Self.appPID)
        var tree = Self.signedIn(prompt: true)
        tree.roots[0].children[0].children.append(under)
        let backend = Self.prompting([tree])

        let error = await #expect(throws: CLIError.self) {
            try await Self.tap(["--id", "under-save"], on: backend)
        }

        #expect(error?.userFacingDescription == "--id 'under-save' at (275, 547) is under the system prompt 'Save Password?' from SafariViewService, so the tap would land on its button 'Save' (205, 523) 140x48. Nothing was sent. Answer the prompt (its buttons are not in describe-ui, so take a screenshot to find them), then retry; or pass --allow-covered to tap anyway.")
        #expect(error?.coveredBy?.label == "Save")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--allow-covered taps under the prompt")
    func allowCoveredTaps() async throws {
        let backend = Self.prompting([Self.signedIn(prompt: true)])

        try await Self.tap(["--id", "sign-out", "--allow-covered"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 241))])
    }

    @Test("with no host in the tree, empty containers still never cover: tap makes no hit-test")
    func noHostNoHitTest() async throws {
        let backend = Self.prompting([Self.signedIn(prompt: false)])

        try await Self.tap(["--id", "sign-out"], on: backend)

        #expect(backend.hitTests == 0)
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 241))])
    }

    @Test("a host whose hit-test answers with the target taps after one hit-test")
    func hostButTargetAnswers() async throws {
        let backend = HitTestingFakeBackend(trees: [Self.signedIn(prompt: true)])
        backend.hits = { _ in Self.signOut }

        try await Self.tap(["--id", "sign-out"], on: backend)

        #expect(backend.hitTests == 1)
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 241))])
    }

    @Test("type --into-id refuses under the prompt and types nothing")
    func typeIntoRefuses() async {
        var tree = Self.signedIn(prompt: true)
        tree.roots[0].children[0].children.append(FakeUI.node(.textField, id: "note-field", label: "Note", frame: FakeUI.frame(16, 300, 370, 44), pid: Self.appPID))
        let backend = Self.prompting([tree])

        let error = await #expect(throws: CLIError.self) {
            try await TypeIntoTests.quiet {
                try await Type.parse(["--into-id", "note-field", "hi", "--device", Self.device.rawValue])
                    .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
            }
        }

        #expect(error?.reason == .targetCovered)
        #expect(error?.userFacingDescription.hasSuffix("or tap the field with `offsider tap --allow-covered` and type without --into-id.") == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("describe-ui names the prompt as a system window from one read at the middle of the screen")
    func describeNamesPrompt() async throws {
        let backend = Self.prompting([Self.signedIn(prompt: true)])

        let summary = try await Self.describe(["--summary"], on: backend)
        #expect(summary.hasPrefix("# ios fake-device\n# window: Save Password? (system)\n"), "\(summary)")
        #expect(backend.hitPoints == [UIPoint(x: 201, y: 437)])

        let json = try await Self.describe([], on: Self.prompting([Self.signedIn(prompt: true)]))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let window = try #require((object["context"] as? [String: Any])?["window"] as? [String: Any])
        #expect(window["title"] as? String == "Save Password?")
        #expect(window["kind"] as? String == "system")
        #expect(window["package"] as? String == "SafariViewService")
    }

    @Test("describe-ui makes no hit-test without a host, and names nothing when the app answers at the middle")
    func describeWithoutPrompt() async throws {
        let plain = Self.prompting([Self.signedIn(prompt: false)])
        let summary = try await Self.describe(["--summary"], on: plain)
        #expect(!summary.contains("# window"))
        #expect(plain.hitTests == 0)

        let gone = HitTestingFakeBackend(trees: [Self.signedIn(prompt: true)])
        gone.hits = { _ in Self.group(Self.screen) }
        let json = try await Self.describe([], on: gone)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["context"] as? [String: Any])?["window"] is NSNull)
        #expect(gone.hitTests == 1)
    }
}
