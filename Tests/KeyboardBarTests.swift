import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// The bar iOS draws beside the keys, in the shapes read from iOS 27.2 simulators (an iPhone in portrait and landscape, an iPad docked and floating); every suggestion is invented.
@Suite("iOS keyboard bar", .personOutput)
@MainActor
struct KeyboardBarTests {
    static let suggestions = ["Avery Example", "avery@example.com", "0400 000 000"]

    /// One element in the key set idb and the device runner send.
    static func element(
        _ type: String, id: String? = nil, label: String? = nil, value: String? = nil,
        _ frame: (x: Double, y: Double, width: Double, height: Double), focused: Bool = false, _ children: [[String: Any]] = []
    ) -> [String: Any] {
        var element: [String: Any] = [
            "type": type, "frame": ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height], "children": children,
        ]
        if let id { element["AXUniqueId"] = id }
        if let label { element["AXLabel"] = label }
        if let value { element["AXValue"] = value }
        if focused { element["focused"] = true }
        return element
    }

    static func tree(width: Double, height: Double, _ children: [[String: Any]]) throws -> UITree {
        let app = element("Application", label: "Playground", (0, 0, width, height), children)
        let data = try JSONSerialization.data(withJSONObject: [app])
        return UITree(platform: .ios, device: "IOS-UDID", roots: try IOSAccessibilityMapping.tree(fromJSON: data).roots)
    }

    static func field(_ frame: (x: Double, y: Double, width: Double, height: Double), focused: Bool = true) -> [String: Any] {
        element("TextField", id: "note-field", value: "Dear Av", frame, focused: focused)
    }

    /// The bar as a simulator lists it: a page that scrolls taller than the screen, then one cell per suggestion.
    static func bar(_ frame: (x: Double, y: Double, width: Double, height: Double), cells: [String] = suggestions) -> [String: Any] {
        let cell = frame.width / Double(max(cells.count, 1))
        return element("Group", id: "SystemInputAssistantView", frame, [
            element("Group", id: "CenterPageView", frame, [
                element("Group", (frame.x, -35, frame.width, 1244), [element("ScrollArea", frame)]),
                element("Group", label: "Typing Predictions", frame, cells.enumerated().map { index, text in
                    element("Button", label: text, (frame.x + Double(index) * cell, frame.y, cell, frame.height))
                }),
            ]),
        ])
    }

    /// The keys group of an iOS 27 simulator: no Keyboard element, buttons for keys.
    static func keys(_ frame: (x: Double, y: Double, width: Double, height: Double)) -> [String: Any] {
        element("Group", id: "UIKeyboardLayoutStar Preview", frame, [
            element("Button", label: "q", (frame.x + 4, frame.y + 7, 41, 56)),
            element("Button", id: "shift", label: "shift", (frame.x + 4, frame.y + 119, 53, 56)),
            element("Button", id: "Return", label: "return", (frame.x + frame.width - 106, frame.y + 175, 103, 56)),
        ])
    }

    static func area(_ frame: (x: Double, y: Double, width: Double, height: Double)) -> [String: Any] {
        element("Group", id: "inputView", frame)
    }

    static func portrait(bar shown: Bool = true) throws -> UITree {
        try tree(width: 420, height: 912, [
            field((16, 180, 388, 34)),
            area(shown ? (0, 565, 420, 347) : (0, 592, 420, 320)),
        ] + (shown ? [bar((0, 565, 420, 44))] : []) + [keys((0, 609, 420, 245))])
    }

    /// Every string the tree carries, as output, selectors and the cache could read it.
    static func texts(_ tree: UITree) -> [String] {
        tree.roots.flatMap { $0.flattened() }.flatMap { node -> [String?] in
            guard case .ios(let attributes) = node.native else { return [node.label, node.value] }
            return [node.label, node.value, attributes.title, attributes.help, attributes.hint]
        }.compactMap { $0 }
    }

    static func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> UIFrame {
        UIFrame(x: x, y: y, width: width, height: height)
    }

    // MARK: - Trees

    @Test("a mapped tree holds no suggestion: the bar's cells read as hidden, keys and the app's own text stay")
    func mappingHidesSuggestions() throws {
        let tree = try Self.portrait()
        let texts = Self.texts(tree)

        #expect(!texts.contains { text in Self.suggestions.contains { text.contains($0) } })
        #expect(texts.contains("Dear Av"))
        #expect(texts.contains("q") && texts.contains("return"))
        let bar = try #require(tree.roots[0].flattened().first { $0.id == "SystemInputAssistantView" })
        #expect(bar.frame == Self.frame(0, 565, 420, 44))
        let cells = bar.flattened().filter { $0.role == .button }
        #expect(cells.map(\.label) == [KeyboardText.marker, KeyboardText.marker, KeyboardText.marker])
        #expect(cells.map(\.frame?.x) == [0, 140, 280])
    }

    @Test("describe-ui counts the hidden cells once each, and the cache copy holds none of their text")
    func countsAndCache() throws {
        let tree = try Self.portrait()

        #expect(tree.redacted().redaction?.keyboard == 3)
        let cached = tree.redacted(scope: .cache)
        #expect(!Self.texts(cached).contains { text in Self.suggestions.contains { text.contains($0) } })
    }

    @Test("a tree with no bar is left as it was read")
    func noBarNoChange() throws {
        let tree = try Self.portrait(bar: false)

        #expect(!Self.texts(tree).contains(KeyboardText.marker))
        #expect(tree.redacted().redaction?.keyboard == 0)
    }

    @Test("a point read's answer has no parents, so it is hidden by where the last whole read put the bar")
    func pointAnswer() throws {
        let tree = try Self.portrait()
        let bars = KeyboardBar.frames(in: tree.roots)
        let cell = FakeUI.node(.button, label: "Avery Example", frame: Self.frame(0, 565, 140, 44))
        let key = FakeUI.node(.button, label: "q", frame: Self.frame(4, 616, 41, 56))

        #expect(bars == [Self.frame(0, 565, 420, 44)])
        #expect(KeyboardBar.hiding(cell, inside: bars).label == KeyboardText.marker)
        #expect(KeyboardBar.hiding(key, inside: bars).label == "q")
        #expect(KeyboardBar.hiding(cell, inside: []).label == "Avery Example")
    }

    /// The keyboard as the XCUITest runner's snapshot lists it (read from the runner on an iOS 27.2 simulator): the bar under the same id, and a Keyboard element that starts below it.
    static func runnerKeyboard(bar shown: Bool) -> [[String: Any]] {
        let rows = element("Keyboard", (0, 609, 420, 245), [
            element("Other", id: "UIKeyboardLayoutStar Preview", (0, 609, 420, 245), [
                element("Key", label: "Padding-Left", (0, 609, 0, 0)),
                element("Key", label: "q", (4, 616, 41, 56)),
                element("Button", id: "shift", label: "shift", (4, 728, 53, 56)),
                element("Button", id: "Return", label: "return", (314, 784, 103, 56)),
            ]),
        ])
        let cells = element("Other", id: "SystemInputAssistantView", (0, 565, 420, 44), [
            element("Other", label: "Typing Predictions", (0, 565, 420, 44), suggestions.enumerated().map { index, text in
                element("Button", label: text, (Double(index) * 140, 565, 140, 44))
            }),
        ])
        return [
            element("Other", id: "inputView", shown ? (0, 565, 420, 347) : (0, 592, 420, 320)),
            element("Other", (0, 565, 420, 347), (shown ? [cells] : []) + [rows]),
            element("Other", (0, 609, 420, 303), [element("Button", label: "Emoji", (2, 843, 80, 68))]),
        ]
    }

    @Test("the runner's snapshot, as a device sends it, hides the same bar, keeps keys and buttons, and paints the bar alone")
    func runnerSnapshot() throws {
        let tree = try Self.tree(width: 420, height: 912, [Self.field((16, 180, 388, 34))] + Self.runnerKeyboard(bar: true))
        let labels = tree.roots[0].flattened().compactMap(\.label)

        #expect(labels == ["Playground", KeyboardText.marker, KeyboardText.marker, KeyboardText.marker, KeyboardText.marker, "Padding-Left", "q", "shift", "return", "Emoji"])
        #expect(KeyboardBar.placement(in: tree) == KeyboardBar.Placement(frames: [Self.frame(0, 565, 420, 44)]))
        #expect(tree.redacted().redaction?.keyboard == 3)
    }

    @Test("the runner's snapshot of a keyboard with no bar paints nothing and hides nothing")
    func runnerSnapshotNoBar() throws {
        let tree = try Self.tree(width: 420, height: 912, [Self.field((16, 180, 388, 34))] + Self.runnerKeyboard(bar: false))

        #expect(KeyboardBar.placement(in: tree).isEmpty)
        #expect(!Self.texts(tree).contains(KeyboardText.marker))
    }

    @Test("a keyboard element that spans a bar it does not name hides what it holds above its keys, and all of it when it lists no keys")
    func wholeKeyboard() throws {
        let cells = Self.element("Other", label: "Typing Predictions", (0, 500, 390, 45), Self.suggestions.enumerated().map { index, text in
            Self.element("Other", label: text, (Double(index) * 130, 500, 130, 45))
        })
        let rows = [
            Self.element("Key", label: "q", (4, 552, 36, 46)),
            Self.element("Button", id: "shift", label: "shift", (4, 660, 46, 46)),
            Self.element("Button", label: "Dictate", (330, 790, 50, 50)),
        ]
        let standard = try Self.tree(width: 390, height: 844, [Self.element("Keyboard", (0, 500, 390, 344), [cells] + rows)])
        let foreign = try Self.tree(width: 390, height: 844, [Self.element("Keyboard", (0, 500, 390, 344), [
            Self.element("Button", label: "Avery Example", (0, 500, 130, 45)), Self.element("Button", label: "q", (4, 552, 36, 46)),
        ])])

        let labels = standard.roots[0].flattened().compactMap(\.label)
        #expect(labels == ["Playground", KeyboardText.marker, KeyboardText.marker, KeyboardText.marker, KeyboardText.marker, "q", "shift", "Dictate"])
        #expect(KeyboardBar.placement(in: standard) == KeyboardBar.Placement(frames: [Self.frame(0, 500, 390, 52)], unplaced: true))
        #expect(foreign.roots[0].flattened().compactMap(\.label) == ["Playground", KeyboardText.marker, KeyboardText.marker])
        #expect(KeyboardBar.placement(in: foreign) == KeyboardBar.Placement(frames: [Self.frame(0, 500, 390, 344)]))
    }

    // MARK: - Placement

    @Test("a listed bar is painted where it is: portrait, landscape, an iPad docked and floating")
    func listedBar() throws {
        let landscape = try Self.tree(width: 912, height: 420, [
            Self.field((84, 127, 744, 36)), Self.area((0, 196, 912, 224)), Self.bar((117, 196, 678, 44)), Self.keys((117, 240, 678, 177)),
        ])
        let docked = try Self.tree(width: 820, height: 1180, [
            Self.field((16, 229, 788, 36)), Self.area((0, 843, 820, 337)), Self.bar((0, 843, 820, 55)), Self.keys((0, 898, 820, 279)),
        ])
        let floating = try Self.tree(width: 820, height: 1180, [
            Self.field((16, 229, 788, 36)), Self.bar((250, 683, 320, 44)), Self.keys((250, 727, 320, 225)),
        ])

        #expect(KeyboardBar.placement(in: try Self.portrait()) == KeyboardBar.Placement(frames: [Self.frame(0, 565, 420, 44)]))
        #expect(KeyboardBar.placement(in: landscape) == KeyboardBar.Placement(frames: [Self.frame(117, 196, 678, 44)]))
        #expect(KeyboardBar.placement(in: docked) == KeyboardBar.Placement(frames: [Self.frame(0, 843, 820, 55)]))
        #expect(KeyboardBar.placement(in: floating) == KeyboardBar.Placement(frames: [Self.frame(250, 683, 320, 44)]))
    }

    @Test("a bar with no suggestions yet is painted too, as one can arrive between the read and the capture")
    func emptyBar() throws {
        let tree = try Self.tree(width: 420, height: 912, [
            Self.field((16, 180, 388, 34)), Self.area((0, 565, 420, 347)), Self.bar((0, 565, 420, 44), cells: []), Self.keys((0, 609, 420, 245)),
        ])

        #expect(KeyboardBar.placement(in: tree) == KeyboardBar.Placement(frames: [Self.frame(0, 565, 420, 44)]))
    }

    @Test("keys with no bar, and a keyboard area that leaves no room for one, paint nothing")
    func provenAbsent() throws {
        #expect(KeyboardBar.placement(in: try Self.portrait(bar: false)).isEmpty)
    }

    @Test("a keyboard area that reaches a bar's height above the keys with no bar listed is painted as a band, unplaced")
    func bandInsideArea() throws {
        let tree = try Self.tree(width: 420, height: 912, [Self.field((16, 180, 388, 34)), Self.area((0, 565, 420, 347)), Self.keys((0, 609, 420, 245))])

        #expect(KeyboardBar.placement(in: tree) == KeyboardBar.Placement(frames: [Self.frame(0, 565, 420, 44)], unplaced: true))
    }

    @Test("keys with neither a bar nor a keyboard area, as a floating keyboard lists them, get a band above the keys, unplaced")
    func bandAboveKeys() throws {
        let floating = try Self.tree(width: 820, height: 1180, [Self.field((16, 229, 788, 36)), Self.keys((250, 727, 320, 225))])
        let atTop = try Self.tree(width: 912, height: 420, [Self.keys((117, 40, 678, 177))])

        #expect(KeyboardBar.placement(in: floating) == KeyboardBar.Placement(frames: [Self.frame(250, 663, 320, 64)], unplaced: true))
        #expect(KeyboardBar.placement(in: atTop) == KeyboardBar.Placement(frames: [Self.frame(117, 0, 678, 40)], unplaced: true))
    }

    @Test("a text field in focus with no keys, as with a hardware keyboard, gets a band along the bottom edge, unplaced")
    func hardwareKeyboard() throws {
        let none = try Self.tree(width: 820, height: 1180, [Self.field((16, 229, 788, 36))])
        let belowScreen = try Self.tree(width: 420, height: 912, [Self.field((16, 180, 388, 34)), Self.keys((0, 912, 420, 245))])

        #expect(KeyboardBar.placement(in: none) == KeyboardBar.Placement(frames: [Self.frame(0, 1084, 820, 96)], unplaced: true))
        #expect(KeyboardBar.placement(in: belowScreen) == KeyboardBar.Placement(frames: [Self.frame(0, 816, 420, 96)], unplaced: true))
    }

    @Test("a hardware keyboard's bar that is listed is painted where it is, not as a band")
    func hardwareBarListed() throws {
        let tree = try Self.tree(width: 820, height: 1180, [Self.field((16, 229, 788, 36)), Self.bar((150, 1110, 520, 55))])

        #expect(KeyboardBar.placement(in: tree) == KeyboardBar.Placement(frames: [Self.frame(150, 1110, 520, 55)]))
    }

    @Test("no keyboard and no field in focus paints nothing: a bar left below the screen, a field without focus, an Android tree")
    func nothingToPaint() throws {
        let parked = try Self.tree(width: 420, height: 912, [
            Self.field((16, 180, 388, 34), focused: false), Self.bar((0, 912, 420, 44)), Self.keys((0, 956, 420, 245)),
        ])
        let android = FakeUI.tree(platform: .android, [
            FakeUI.node(.textField, id: "note-field", frame: Self.frame(16, 180, 388, 34), state: UIState(focused: true), platform: .android),
        ])

        #expect(KeyboardBar.placement(in: parked).isEmpty)
        #expect(KeyboardBar.placement(in: android).isEmpty)
    }

    @Test("a field in focus on a screen with no size withholds the capture rather than guess a band")
    func noViewport() {
        let field = FakeUI.node(.textField, id: "note-field", frame: Self.frame(16, 180, 388, 34), state: UIState(focused: true))
        let tree = UITree(platform: .ios, device: "IOS-UDID", roots: [field])

        #expect(KeyboardBar.placement(in: tree) == KeyboardBar.Placement(frames: [nil], unplaced: true))
    }

    // MARK: - Captures

    static func fakeBar(cells: [String] = suggestions) -> UINode {
        FakeUI.node(.group, id: "SystemInputAssistantView", frame: frame(0, 500, 390, 44), children: cells.enumerated().map { index, text in
            FakeUI.node(.button, label: text, frame: frame(Double(index) * 130, 500, 130, 44))
        })
    }

    static func fakeKeys() -> UINode {
        FakeUI.node(.keyboard, id: "UIKeyboardLayoutStar Preview", frame: frame(0, 544, 390, 245), children: [
            FakeUI.node(.button, label: "q", frame: frame(4, 551, 36, 56)),
        ])
    }

    @Test("screenshot paints the whole bar as one keyboard mask and leaves the keys and the app's own bar above it")
    func screenshotPaintsBar() async throws {
        let done = FakeUI.node(.button, id: "form-done", label: "Done", frame: Self.frame(320, 460, 60, 36))
        let backend = try ScreenshotMaskTests.backend([done, Self.fakeBar(), Self.fakeKeys()])
        let shot = try await ScreenshotMaskTests.capture(["--json"], on: backend, environment: [:])
        defer { try? FileManager.default.removeItem(atPath: shot.path) }

        #expect(shot.report.maskedBy?[.keyboard] == 1)
        #expect(shot.report.maskUnproven == nil)
        #expect(ScreenshotMaskTests.point(shot.image, 5, 502) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.point(shot.image, 385, 542) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.point(shot.image, 350, 478) == ScreenshotMaskTests.white)
        #expect(ScreenshotMaskTests.point(shot.image, 20, 580) == ScreenshotMaskTests.white)
        #expect(backend.treeReads == 1)
    }

    @Test("a keyboard with no bar listed and no keyboard area gets a band, reported as maskUnproven keyboard with one warning")
    func screenshotBand() async throws {
        let backend = try ScreenshotMaskTests.backend([Self.fakeKeys()])
        let capture = ConsoleCapture()
        let shot = try await Console.$current.withValue(AgentOutputTests.agentConsole(capture)) {
            try await ScreenshotMaskTests.capture(["--json"], on: backend, environment: [:])
        }
        defer { try? FileManager.default.removeItem(atPath: shot.path) }

        #expect(shot.report.maskedBy?[.keyboard] == 1)
        #expect(shot.report.maskUnproven == "keyboard")
        #expect(shot.report.jsonLine().contains(#""maskUnproven":"keyboard""#))
        #expect(ScreenshotMaskTests.point(shot.image, 195, 500) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.point(shot.image, 195, 470) == ScreenshotMaskTests.white)
        let warnings = capture.err.split(separator: "\n").filter { $0.contains("(maskUnproven)") }
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("a band was painted") == true && warnings.first?.contains("offsider keyboard hide") == true, "\(capture.err)")
    }

    @Test("with password masking turned off the bar is not painted, as on Android")
    func screenshotUnmasked() async throws {
        let backend = try ScreenshotMaskTests.backend([Self.fakeBar(), Self.fakeKeys()])
        let shot = try await ScreenshotMaskTests.capture(["--json"], on: backend)
        defer { try? FileManager.default.removeItem(atPath: shot.path) }

        #expect(shot.report.maskedBy == nil)
        #expect(ScreenshotMaskTests.point(shot.image, 5, 502) == ScreenshotMaskTests.white)
    }

    @Test("a capture with no keyboard up reads the tree once and paints nothing for it")
    func noKeyboardNoCost() async throws {
        let label = FakeUI.node(.text, label: "Welcome", frame: Self.frame(20, 100, 200, 20))
        let backend = try ScreenshotMaskTests.backend([label])
        let shot = try await ScreenshotMaskTests.capture(["--json"], on: backend, environment: [:])
        defer { try? FileManager.default.removeItem(atPath: shot.path) }

        #expect(shot.report.maskedBy?[.keyboard] == nil)
        #expect(shot.report.maskUnproven == nil)
        #expect(backend.treeReads == 1)
    }

    // MARK: - Video

    @Test("video refuses while the bar shows, with suggestions or none, and names a keyboard it cannot place")
    func videoRefuses() throws {
        let shown = FakeUI.tree(width: 390, height: 844, [Self.fakeBar(), Self.fakeKeys()])
        let empty = FakeUI.tree(width: 390, height: 844, [Self.fakeBar(cells: []), Self.fakeKeys()])
        let unplaced = FakeUI.tree(width: 390, height: 844, [Self.fakeKeys()])
        let none = FakeUI.tree(width: 390, height: 844, [FakeUI.node(.text, label: "Welcome", frame: Self.frame(20, 100, 200, 20))])

        #expect(VideoMaskPolicy.keyboardTextRefusal(command: "record-video", in: shown)?.contains("shows suggestions") == true)
        #expect(VideoMaskPolicy.keyboardTextRefusal(command: "record-video", in: empty)?.contains("shows suggestions") == true)
        #expect(VideoMaskPolicy.keyboardTextRefusal(command: "record-video", in: unplaced)?.contains("cannot be placed") == true)
        #expect(VideoMaskPolicy.keyboardTextRefusal(command: "record-video", in: none) == nil)
    }

    // MARK: - Hiding the keyboard

    @Test("the keyboard's own way out is found in an app's Done bar that rides above the suggestions, never in Return")
    func doneAboveSuggestions() throws {
        let done = Self.element("Button", id: "form-done", label: "Done", (331, 523, 63, 36))
        let withBar = try Self.tree(width: 420, height: 912, [
            Self.field((16, 180, 388, 34)), done, Self.area((0, 565, 420, 347)), Self.bar((0, 565, 420, 44)), Self.keys((0, 609, 420, 245)),
        ])
        let lowDone = Self.element("Button", id: "form-done", label: "Done", (331, 550, 63, 36))
        let withoutBar = try Self.tree(width: 420, height: 912, [
            Self.field((16, 180, 388, 34)), lowDone, Self.area((0, 592, 420, 320)), Self.keys((0, 609, 420, 245)),
        ])

        #expect(KeyboardHide.step(in: withBar) == .control(UIPoint(x: 362.5, y: 541)))
        #expect(KeyboardHide.step(in: withoutBar) == .control(UIPoint(x: 362.5, y: 568)))
        #expect(KeyboardHide.step(in: try Self.portrait()) == .noWayOut)
    }

    @Test("an iPad's hide key is the way out; Android sends Back only over docked keys; no keyboard sends nothing")
    func steps() throws {
        let hideKey = FakeUI.node(.button, label: "Hide keyboard", frame: Self.frame(720, 1096, 98, 63))
        let pad = FakeUI.tree(width: 820, height: 1180, [
            FakeUI.node(.keyboard, id: "UIKeyboardLayoutStar Preview", frame: Self.frame(0, 898, 820, 279), children: [hideKey]),
        ])
        let docked = UITree(platform: .android, device: "emulator-5554", roots: [
            FakeUI.node(.application, frame: Self.frame(0, 0, 411, 914), platform: .android),
            FakeUI.node(.keyboard, frame: Self.frame(0, 600, 411, 314), platform: .android, children: [
                FakeUI.node(.button, label: "q", frame: Self.frame(4, 620, 400, 280), platform: .android),
            ]),
        ])
        let toolbar = UITree(platform: .android, device: "emulator-5554", roots: [
            FakeUI.node(.application, frame: Self.frame(0, 0, 411, 914), platform: .android),
            FakeUI.node(.keyboard, frame: Self.frame(300, 860, 100, 40), platform: .android, children: [
                FakeUI.node(.button, label: "Open features menu", frame: Self.frame(300, 860, 40, 40), platform: .android),
            ]),
        ])

        #expect(KeyboardHide.step(in: pad) == .control(UIPoint(x: 769, y: 1127.5)))
        #expect(KeyboardHide.step(in: docked) == .back)
        #expect(KeyboardHide.step(in: toolbar) == .absent)
        #expect(KeyboardHide.step(in: FakeUI.tree([])) == .absent)
    }

    @Test("empty space can be offered beside a bar whose page scrolls taller than the screen")
    func outsidePointPastBar() throws {
        let tree = try Self.portrait()
        let point = try #require(KeyboardHide.outsidePoint(in: tree, tried: []))

        #expect(point.y < 565)
        #expect(!Self.frame(16, 180, 388, 34).contains(point))
    }

    /// Runs `Keyboard.hide` over scripted trees: `after` is read once something was sent.
    static func hide(before: UITree, after: UITree, tapOutside: Bool = false) async throws -> (outcome: Result<Keyboard.Outcome, Error>, sent: [String]) {
        var sent: [String] = []
        let outcome: Result<Keyboard.Outcome, Error>
        do {
            outcome = .success(try await Keyboard.hide(
                tapOutside: tapOutside, device: "IOS-UDID",
                read: { sent.isEmpty ? before : after },
                ownWayOut: { _ in sent.append("own") },
                tap: { _, _ in sent.append("tap") },
                sleep: { _ in }
            ))
        } catch {
            outcome = .failure(error)
        }
        return (outcome, sent)
    }

    @Test("keyboard hide sends nothing with no keyboard, and reports hidden once its own way out worked")
    func hideOutcomes() async throws {
        let none = FakeUI.tree([])
        let done = Self.element("Button", id: "form-done", label: "Done", (331, 523, 63, 36))
        let up = try Self.tree(width: 420, height: 912, [done, Self.area((0, 565, 420, 347)), Self.bar((0, 565, 420, 44)), Self.keys((0, 609, 420, 245))])

        let absent = try await Self.hide(before: none, after: none)
        #expect(try absent.outcome.get() == .absent)
        #expect(absent.sent.isEmpty)
        let hidden = try await Self.hide(before: up, after: none)
        #expect(try hidden.outcome.get() == .hidden)
        #expect(hidden.sent == ["own"])
    }

    @Test("keyboard hide fails with state_not_reached and sends nothing when the keyboard has no way out, unless --tap-outside")
    func hideWithoutWayOut() async throws {
        let up = try Self.portrait()

        let refused = try await Self.hide(before: up, after: FakeUI.tree([]))
        #expect(refused.sent.isEmpty)
        let failure = try #require({ if case .failure(let error) = refused.outcome { return error as? CLIError } else { return nil } }())
        #expect(failure.reason == .stateNotReached)
        #expect(failure.hint == "offsider keyboard hide --tap-outside --device IOS-UDID")

        let tapped = try await Self.hide(before: up, after: FakeUI.tree([]), tapOutside: true)
        #expect(try tapped.outcome.get() == .hidden)
        #expect(tapped.sent == ["tap"])
    }

    @Test("--tap-outside never spends a try on the hide key the own way out already pressed")
    func tapOutsideSkipsTheHideKey() async throws {
        let hideKey = FakeUI.node(.button, label: "Hide keyboard", frame: Self.frame(720, 1096, 98, 63))
        let pad = FakeUI.tree(width: 820, height: 1180, [
            FakeUI.node(.keyboard, id: "UIKeyboardLayoutStar Preview", frame: Self.frame(0, 898, 820, 279), children: [hideKey]),
        ])
        var taps: [UIPoint] = []
        _ = try? await Keyboard.hide(
            tapOutside: true, device: "IOS-UDID", read: { pad }, ownWayOut: { _ in }, tap: { point, _ in taps.append(point) }, sleep: { _ in }
        )

        #expect(taps.count == 3)
        #expect(taps.allSatisfy { !Self.frame(720, 1096, 98, 63).contains($0) }, "\(taps)")
    }

    @Test("a tap the iOS keyboard covers names keyboard hide when the keyboard has a way out, and only then")
    func tapHintNamesKeyboardHide() throws {
        let device = DeviceID(rawValue: "IOS-UDID", platform: .ios)
        let done = Self.element("Button", id: "form-done", label: "Done", (331, 523, 63, 36))
        let withDone = try Self.tree(width: 420, height: 912, [done, Self.area((0, 565, 420, 347)), Self.bar((0, 565, 420, 44)), Self.keys((0, 609, 420, 245))])

        let offered = Tap.keyboardCoverError(selector: "id=save", at: (x: 200, y: 700), device: device, tree: withDone)
        let plain = Tap.keyboardCoverError(selector: "id=save", at: (x: 200, y: 700), device: device, tree: try Self.portrait())

        #expect(offered.hint == "offsider keyboard hide --device IOS-UDID")
        #expect(offered.userFacingDescription.contains("`offsider keyboard hide`"))
        #expect(plain.hint == "offsider describe-ui --summary --device IOS-UDID")
        #expect(!plain.userFacingDescription.contains("keyboard hide"))
    }

    @Test("a bar inside a device's keyboard element is found for point answers too")
    func nestedBarFrames() throws {
        let tree = try Self.tree(width: 390, height: 844, [Self.element("Keyboard", (0, 500, 390, 344), [
            Self.bar((0, 500, 390, 45)), Self.element("Key", label: "q", (4, 552, 36, 46)),
        ])])

        #expect(KeyboardBar.frames(in: tree.roots) == [Self.frame(0, 500, 390, 45)])
        #expect(KeyboardBar.placement(in: tree) == KeyboardBar.Placement(frames: [Self.frame(0, 500, 390, 45)]))
    }

    @Test("--tap-outside stops after three taps that leave the keyboard up")
    func tapOutsideGivesUp() async throws {
        let up = try Self.portrait()

        let stuck = try await Self.hide(before: up, after: up, tapOutside: true)
        #expect(stuck.sent == ["tap", "tap", "tap"])
        let failure = try #require({ if case .failure(let error) = stuck.outcome { return error as? CLIError } else { return nil } }())
        #expect(failure.reason == .stateNotReached)
        #expect(failure.userFacingDescription.contains("3 taps"))
    }
}
