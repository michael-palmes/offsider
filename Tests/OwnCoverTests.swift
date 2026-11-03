import AppKit
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A button under its own screen's empty wrappers taps; anything that could really take the touch still refuses.
@Suite("Own screen covers")
@MainActor
struct OwnCoverTests {
    static let width = 400.0, height = 800.0
    static let send = FakeUI.frame(16, 700, 368, 50)

    static func group(id: String? = nil, _ frame: UIFrame? = nil, order: Int, _ children: [UINode] = []) -> UINode {
        var node = TapCoverTests.classed(
            FakeUI.node(.group, id: id, frame: frame ?? FakeUI.frame(0, 0, width, height), platform: .android, drawingOrder: order),
            "android.view.ViewGroup"
        )
        node.children = children
        return node
    }

    static func button(_ id: String, _ label: String, _ frame: UIFrame, order: Int) -> UINode {
        FakeUI.node(.button, id: id, label: label, frame: frame, platform: .android, drawingOrder: order)
    }

    static func text(_ label: String, _ frame: UIFrame, order: Int) -> UINode {
        FakeUI.node(.text, label: label, frame: frame, platform: .android, drawingOrder: order)
    }

    static func tree(_ children: [UINode]) -> UITree {
        FakeUI.tree(platform: .android, width: width, height: height, children)
    }

    /// A screen and the one beneath it, both built by the same layout: each holds its content, then the same `wrapper` drawn last.
    static func screens(wrapper given: UINode? = nil) -> UITree {
        let wrapper = given ?? group(order: 3)
        let beneath = group(order: 1, [
            group(order: 1, [text("Earlier Screen", FakeUI.frame(16, 60, 368, 30), order: 1), text("Earlier Body", FakeUI.frame(16, 400, 368, 30), order: 2)]),
            wrapper,
        ])
        let front = group(order: 2, [
            group(order: 1, [text("Step Title", FakeUI.frame(16, 60, 368, 30), order: 1), text("Step Body", FakeUI.frame(16, 400, 368, 30), order: 2), button("send", "Send", send, order: 3)]),
            wrapper,
        ])
        return tree([beneath, front])
    }

    // MARK: Passes

    @Test("a button under its screen's empty wrapper taps, though the screen beneath holds a wrapper just like it")
    func identicalWrapperBeneath() throws {
        #expect(try TapCoverTests.judge(Self.screens(), target: "send", hit: nil) == nil)
    }

    @Test("an empty wrapper that looks just like the group holding the button is not taken for it, and taps")
    func wrapperLikeItsOwnAncestor() throws {
        let content = Self.group(order: 1, [Self.text("Step Title", FakeUI.frame(16, 60, 368, 30), order: 1), Self.text("Step Body", FakeUI.frame(16, 400, 368, 30), order: 2), Self.button("send", "Send", Self.send, order: 3)])
        let front = Self.group(order: 2, [content, Self.group(order: 2), Self.group(order: 3)])
        let beneath = Self.group(order: 1, [Self.text("Earlier Screen", FakeUI.frame(16, 60, 368, 30), order: 1), Self.text("Earlier Body", FakeUI.frame(16, 400, 368, 30), order: 2)])
        #expect(try TapCoverTests.judge(Self.tree([beneath, front]), target: "send", hit: nil) == nil)
    }

    static let drawer = FakeUI.frame(6, 40, 36, 36)

    /// A header holding a drawer button and, drawn after it, `slot`.
    static func header(slot: UINode) -> UITree {
        let header = group(FakeUI.frame(0, 30, width, 90), order: 1, [button("drawer", "Open Drawer", drawer, order: 1), slot])
        return tree([header, text("Body", FakeUI.frame(16, 300, 368, 30), order: 2)])
    }

    @Test("a drawer button under an empty slot of its own header taps")
    func emptySlotOfItsHeader() throws {
        #expect(try TapCoverTests.judge(Self.header(slot: Self.group(FakeUI.frame(0, 34, 70, 70), order: 2)), target: "drawer", hit: nil) == nil)
    }

    // MARK: Refusals

    @Test("the same slot with no part of the screen shared with the button says nothing, so it refuses, naming the slot")
    func slotBesideTheHeader() throws {
        let slot = Self.group(FakeUI.frame(0, 34, 70, 70), order: 3)
        let verdict = try #require(try TapCoverTests.judge(Self.tree([Self.button("drawer", "Open Drawer", Self.drawer, order: 1), Self.text("Body", FakeUI.frame(16, 300, 368, 30), order: 2), slot]), target: "drawer", hit: nil))
        #expect(verdict.cover.frame == slot.frame)
        #expect(verdict.evidence == .drawingOrder && !verdict.isConfident)
    }

    @Test("a slot holding text is something drawn, so it refuses")
    func slotWithContent() throws {
        let slot = Self.group(FakeUI.frame(0, 34, 70, 70), order: 2, [Self.text("New", FakeUI.frame(40, 80, 25, 20), order: 1)])
        let verdict = try #require(try TapCoverTests.judge(Self.header(slot: slot), target: "drawer", hit: nil))
        #expect(verdict.cover.frame == slot.frame)
    }

    @Test("a control in the header drawn over the button is a confident cover")
    func controlOverDrawerButton() throws {
        let verdict = try #require(try TapCoverTests.judge(Self.header(slot: Self.button("badge", "Alerts", FakeUI.frame(0, 34, 70, 70), order: 2)), target: "drawer", hit: nil))
        #expect(verdict.cover.id == "badge" && verdict.isConfident)
    }

    @Test("a veil over a whole screen with no page found is a guessed cover")
    func veilOffEveryPage() throws {
        let screen = [Self.button("send", "Send", Self.send, order: 1), Self.text("Body", FakeUI.frame(16, 300, 368, 30), order: 2)]
        let verdict = try #require(try TapCoverTests.judge(Self.tree(screen + [Self.group(order: 3)]), target: "send", hit: nil))
        #expect(verdict.evidence == .drawingOrder && !verdict.isConfident)
    }

    @Test("a scrim that takes presses is a confident cover, even on the button's own page")
    func pressableScrim() throws {
        let verdict = try #require(try TapCoverTests.judge(Self.screens(wrapper: Self.button("scrim", "Dismiss", FakeUI.frame(0, 0, Self.width, Self.height), order: 3)), target: "send", hit: nil))
        #expect(verdict.cover.id == "scrim" && verdict.isConfident)
    }

    @Test("a screen-wide view holding a sheet on the button's own page refuses, though nothing of the sheet lies at the point")
    func sheetOnOwnPage() throws {
        let sheet = Self.group(order: 3, [Self.text("Sheet Title", FakeUI.frame(16, 60, 368, 30), order: 1)])
        let verdict = try #require(try TapCoverTests.judge(Self.screens(wrapper: sheet), target: "send", hit: nil))
        #expect(verdict.cover.frame == sheet.frame)
        #expect(!verdict.isConfident)
    }

    @Test("a control on the page over the button's screen refuses, naming it, whatever empty views lie over both")
    func pageOverTheButton() throws {
        let cover = Self.button("over", "Next", Self.send, order: 2)
        let lower = Self.group(order: 1, [Self.text("Lower", FakeUI.frame(16, 60, 368, 30), order: 1), Self.button("send", "Send", Self.send, order: 2), Self.group(order: 3)])
        let upper = Self.group(order: 2, [Self.text("Upper", FakeUI.frame(16, 60, 368, 30), order: 1), cover, Self.group(order: 3)])
        let verdict = try #require(try TapCoverTests.judge(Self.tree([lower, upper]), target: "send", hit: nil))
        #expect(verdict.cover.id == "over" && verdict.isConfident)
    }

    // MARK: A screenshot decides what the tree cannot

    /// One screen with only an empty view drawn over its button, off every page, as a screen's own wrapper and a veil both read.
    static func emptyViewOverButton(label: String = "Send") -> UITree {
        tree([button("send", label, send, order: 1), text("Body", FakeUI.frame(16, 300, 368, 30), order: 2), group(order: 3)])
    }

    /// A screenshot of the screen, with `text` drawn where the button sits, on a blank background.
    static func screenshot(showing text: String?) throws -> Data {
        let scale = 2.0
        let image = NSImage(size: NSSize(width: width * scale, height: height * scale))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width * scale, height: height * scale).fill()
        if let text {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.black])
                .draw(at: NSPoint(x: (send.x + 120) * scale, y: (height - send.y - send.height + 6) * scale))
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    static let device = DeviceID(rawValue: "fake-device", platform: .android)

    static func tap(_ arguments: [String], tree: UITree, screenshots: [Data]) async throws -> (FakeDeviceBackend, String) {
        let backend = FakeDeviceBackend(trees: [tree, tree], screenshots: screenshots)
        let capture = ConsoleCapture()
        try await Console.$current.withValue(capture.console(out: .agent, err: .agent)) {
            try await TypeIntoTests.quiet {
                try await Tap.parse(arguments + ["--no-settle", "--device", device.rawValue])
                    .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
            }
        }
        return (backend, capture.err)
    }

    @Test("with --fail-if-covered a button whose text shows under an empty view taps, and says why")
    func shownTextTaps() async throws {
        let (backend, stderr) = try await Self.tap(["--id", "send", "--fail-if-covered"], tree: Self.emptyViewOverButton(), screenshots: [try Self.screenshot(showing: "Send")])
        #expect(backend.session.calls.count == 1)
        #expect(backend.screenshotReads == 1)
        #expect(stderr.contains("a screenshot shows its text"), "\(stderr)")
    }

    @Test("with --fail-if-covered a button whose text does not show refuses, naming the view, and sends nothing", arguments: [nil, "Other Words"])
    func hiddenTextRefuses(shown: String?) async throws {
        let backend = FakeDeviceBackend(trees: [Self.emptyViewOverButton(), Self.emptyViewOverButton()], screenshots: [try Self.screenshot(showing: shown)])
        let error = await #expect(throws: CLIError.self) {
            try await TypeIntoTests.quiet {
                try await Tap.parse(["--id", "send", "--fail-if-covered", "--no-settle", "--device", Self.device.rawValue])
                    .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
            }
        }
        #expect(error?.reason == .targetCovered)
        #expect(error?.errorDescription?.contains("may be covered by group") == true)
        #expect(error?.errorDescription?.contains("Its text does not show in a screenshot") == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a plain tap takes no screenshot: it only warns, as before")
    func plainTapTakesNoScreenshot() async throws {
        let (backend, stderr) = try await Self.tap(["--id", "send"], tree: Self.emptyViewOverButton(), screenshots: [try Self.screenshot(showing: "Send")])
        #expect(backend.screenshotReads == 0)
        #expect(stderr.contains("may be covered"), "\(stderr)")
    }

    @Test("a screenshot is no help against a control or a view holding content: they refuse without one")
    func screenshotOnlyForEmptyViews() async throws {
        let control = Self.tree([Self.button("send", "Send", Self.send, order: 1), Self.text("Body", FakeUI.frame(16, 300, 368, 30), order: 2), Self.button("over", "Next", Self.send, order: 3)])
        let holding = Self.tree([Self.button("send", "Send", Self.send, order: 1), Self.text("Body", FakeUI.frame(16, 300, 368, 30), order: 2), Self.group(order: 3, [Self.text("Sheet", FakeUI.frame(16, 60, 368, 30), order: 1)])])
        for tree in [control, holding] {
            let backend = FakeDeviceBackend(trees: [tree, tree], screenshots: [try Self.screenshot(showing: "Send")])
            await #expect(throws: CLIError.self) {
                try await TypeIntoTests.quiet {
                    try await Tap.parse(["--id", "send", "--fail-if-covered", "--no-settle", "--device", Self.device.rawValue])
                        .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
                }
            }
            #expect(backend.screenshotReads == 0)
            #expect(backend.session.calls.isEmpty)
        }
    }

    @Test("the label must show whole, whatever its case or punctuation; a one-letter label proves nothing", arguments: [
        ("Send Request", ["SEND REQUEST"], true),
        ("Send Request", ["Send", "Request"], true),
        ("Send Request", ["Send"], false),
        ("Send Request", [], false),
        ("X", ["X"], false),
    ])
    func labelMustShowWhole(label: String, read: [String], shows: Bool) {
        #expect(ShownText.shows(label: label, in: read) == shows)
    }
}
