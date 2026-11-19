import CoreGraphics
import CoreText
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A full-screen iOS modal hides the screen beneath from the tree, as on a device: masks paint where the tree cache last saw what they name.
@Suite("Masks behind an iOS modal", .personOutput)
@MainActor
struct MaskBehindModalTests {
    nonisolated static let email = "sam.fixture@example.com"
    nonisolated static let full = FakeUI.frame(0, 0, 390, 844)
    nonisolated static let fieldFrame = FakeUI.frame(16, 107, 358, 44)
    nonisolated static let device = ScreenshotMaskTests.device

    enum Shape: String, CaseIterable, CustomStringConvertible {
        /// A plain backdrop with a card in the middle: a band nothing lists runs from the top.
        case card
        /// A backdrop that closes the modal when tapped.
        case tap
        /// A plain backdrop with a banner near the top.
        case top

        var description: String { rawValue }
    }

    nonisolated static func field(_ value: String? = email, id: String = "mask-sheet-test-email", frame: UIFrame = fieldFrame) -> UINode {
        FakeUI.node(.textField, id: id, label: "Receipt Email", value: value, frame: frame)
    }

    /// The receipt screen as a read lists it before the modal opens.
    nonisolated static func receipt(_ field: UINode = field(), app: String = "Playground", width: Double = 390, height: Double = 844) -> UITree {
        FakeUI.tree(width: width, height: height, label: app, [FakeUI.node(.group, frame: FakeUI.frame(0, 0, width, height), children: [
            FakeUI.node(.button, id: "BackButton", label: "Offsider Playground", frame: FakeUI.frame(8, 47, 44, 44)),
            FakeUI.node(.header, id: "mask-sheet-test-screen", label: "Mask Sheet", frame: FakeUI.frame(60, 59, 270, 20)),
            field,
            FakeUI.node(.text, id: "mask-sheet-test-address", label: "Address bc1q...7k3m", frame: FakeUI.frame(100, 167, 200, 20)),
            FakeUI.node(.text, id: "mask-sheet-test-txid", label: "Transaction 4a9f...e21b", frame: FakeUI.frame(95, 203, 200, 20)),
            FakeUI.node(.button, id: "mask-sheet-test-open-top", label: "Top Card", frame: FakeUI.frame(140, 500, 110, 44)),
        ])])
    }

    /// The modal over the receipt: the screen beneath lists nothing, as on a device.
    nonisolated static func modal(_ shape: Shape, extra: [UINode] = []) -> UITree {
        let backdrop = shape == .tap ? FakeUI.node(.button, label: "Dismiss Error", frame: full) : FakeUI.node(.group, frame: full)
        let card: [UINode] = shape == .top
            ? [
                FakeUI.node(.group, frame: FakeUI.frame(16, 60, 358, 40)),
                FakeUI.node(.button, id: "mask-sheet-test-cover-close", label: "Close Error", frame: FakeUI.frame(254, 62, 110, 36)),
                FakeUI.node(.header, id: "mask-sheet-test-cover-title", label: "Payment declined", frame: FakeUI.frame(32, 70, 142, 20)),
            ]
            : [
                FakeUI.node(.group, frame: FakeUI.frame(32, 340, 326, 108)),
                FakeUI.node(.header, id: "mask-sheet-test-cover-title", label: "Payment declined", frame: FakeUI.frame(124, 356, 142, 20)),
                FakeUI.node(.button, id: "mask-sheet-test-cover-close", label: "Close Error", frame: FakeUI.frame(140, 388, 110, 44)),
            ]
        return FakeUI.tree(width: 390, height: 844, [FakeUI.node(.group, frame: full, children: [backdrop] + card + extra)])
    }

    /// Another screen of the same app, with a plain background behind its own content, as after a tap moved to it.
    nonisolated static func otherScreen() -> UITree {
        FakeUI.tree(width: 390, height: 844, [FakeUI.node(.group, frame: full, children: [
            FakeUI.node(.group, frame: full),
            FakeUI.node(.button, id: "BackButton", label: "Offsider Playground", frame: FakeUI.frame(8, 47, 44, 44)),
            FakeUI.node(.header, id: "tap-test-screen", label: "Tap Test", frame: FakeUI.frame(60, 59, 270, 20)),
            FakeUI.node(.text, id: "tap-count", label: "Tap Count: 0", frame: FakeUI.frame(145, 150, 100, 20)),
        ])])
    }

    /// A white capture with `lines` drawn dimmed at their points.
    static func png(_ lines: [(String, Double, Double)]) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 1170, height: 2532, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1170, height: 2532))
        let font = CTFontCreateWithName("Helvetica" as CFString, 51, nil)
        for (text, x, y) in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.35, alpha: 1),
            ]
            context.textPosition = CGPoint(x: x * 3, y: 2532 - (y + 14) * 3)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        return try ScreenImage.encode(try #require(context.makeImage()), as: .png)
    }

    /// The receipt drawn dimmed behind the modal, its address but not the email, which a text read would paint on its own.
    static func receiptBehindPNG() throws -> Data {
        try png([("Address bc1q...7k3m", 100, 167), ("Transaction 4a9f...e21b", 95, 203)])
    }

    /// One capture under `fixture`'s cache, as an agent reads it.
    static func capture(
        _ arguments: [String], tree: UITree, png: Data, fixture: TreeCacheFixture, environment: [String: String] = ["OFFSIDER_MASK_SECURE": "0"]
    ) async throws -> (report: ScreenshotReport, image: CGImage, err: String) {
        let console = ConsoleCapture()
        let backend = FakeDeviceBackend(trees: [tree], screenshots: [png], screen: ScreenshotMaskTests.screen)
        let (report, image, _) = try await fixture.run {
            try await Console.$current.withValue(AgentOutputTests.agentConsole(console)) {
                try await ScreenshotMaskTests.capture(arguments, on: backend, environment: environment)
            }
        }
        return (report, image, console.err)
    }

    static func remember(_ tree: UITree, in fixture: TreeCacheFixture, age: TimeInterval = 5, beneath: TreeCacheRecord.Beneath? = nil, over: UITree? = nil) throws {
        var record = fixture.settledRecord(over ?? tree, age: age)
        record.device = device.rawValue
        if over != nil { record.beneath = beneath ?? TreeCacheRecord.Beneath(readAt: fixture.now - age, roots: tree.roots) }
        try fixture.write(record)
    }

    /// Indices of the image's pure black pixels.
    static func blackPixels(_ image: CGImage) throws -> Set<Int> {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ).map { context in
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            } ?? false
        }
        try #require(drawn)
        var black = Set<Int>()
        for pixel in 0..<(image.width * image.height) where bytes[pixel * 4] == 0 && bytes[pixel * 4 + 1] == 0 && bytes[pixel * 4 + 2] == 0 {
            black.insert(pixel)
        }
        return black
    }

    static func fieldPainted(_ image: CGImage) -> Bool {
        ScreenshotMaskTests.point(image, fieldFrame.center.x, fieldFrame.center.y) == ScreenshotMaskTests.black
    }

    // MARK: - Which modals the tree tells

    @Test("a centred card leaves a band, as before; a tappable backdrop is a modal by its shape; a top banner only with a memory")
    func shapes() {
        #expect(HiddenScreen.region(in: Self.modal(.card), belowStatusBar: 60) != nil, "the earlier band rule covers the card")
        #expect(HiddenScreen.region(in: Self.modal(.tap), belowStatusBar: 60) == nil)
        #expect(HiddenScreen.region(in: Self.modal(.top), belowStatusBar: 60) == nil)

        #expect(HiddenScreen.modal(in: Self.modal(.tap), belowStatusBar: 60) == ModalScreen(region: FakeUI.frame(0, 60, 390, 784), hidesBand: false))
        #expect(HiddenScreen.modal(in: Self.modal(.top), belowStatusBar: 60) == nil)
        #expect(HiddenScreen.modal(in: Self.modal(.top), belowStatusBar: 60, remembered: Self.receipt())
            == ModalScreen(region: FakeUI.frame(0, 60, 390, 784), hidesBand: false, byMemory: true))
    }

    @Test("a screen still listed beneath a backdrop, a keyboard that went down and a content area below a header are no modal, even with a memory")
    func notModals() {
        var sheetOverListed = Self.receipt()
        sheetOverListed.roots[0].children[0].children += [FakeUI.node(.group, frame: Self.full), FakeUI.node(.button, label: "Close Sheet", frame: FakeUI.frame(140, 700, 110, 44))]
        #expect(HiddenScreen.modal(in: sheetOverListed, belowStatusBar: 60, remembered: Self.receipt()) == nil)

        var background = Self.receipt()
        background.roots[0].children[0].children.insert(FakeUI.node(.group, frame: Self.full), at: 0)
        var typing = background
        let keys = (0..<30).map { FakeUI.node(.button, label: "k\($0)", frame: FakeUI.frame(Double($0 % 10) * 39, 600 + Double($0 / 10) * 54, 39, 54)) }
        typing.roots[0].children.append(FakeUI.node(.keyboard, frame: FakeUI.frame(0, 590, 390, 254), children: keys))
        #expect(HiddenScreen.modal(in: background, belowStatusBar: 60, remembered: typing) == nil, "the keys going down are no screen gone")

        let area = FakeUI.tree(width: 390, height: 844, [FakeUI.node(.group, frame: Self.full, children: [
            FakeUI.node(.button, id: "BackButton", label: "Offsider Playground", frame: FakeUI.frame(8, 47, 44, 44)),
            FakeUI.node(.header, id: "tap-test-screen", label: "Tap Test", frame: FakeUI.frame(60, 59, 270, 20)),
            FakeUI.node(.group, id: "tap-test-area", frame: FakeUI.frame(0, 106, 390, 738)),
            FakeUI.node(.text, id: "tap-count", label: "Tap Count: 0", frame: FakeUI.frame(145, 150, 100, 20)),
        ])])
        #expect(HiddenScreen.modal(in: area, belowStatusBar: 60, remembered: Self.receipt()) == nil)
    }

    @Test("a text line reading as text the old screen listed shows that screen behind; another screen's own text does not")
    func showsRemembered() {
        let address = ScreenTextLine(text: "Address bc1q...7k3m", frame: FakeUI.frame(100, 167, 200, 20))
        let other = ScreenTextLine(text: "Tap anywhere to count", frame: FakeUI.frame(100, 300, 200, 20))
        #expect(HiddenScreen.showsRemembered([address], remembered: Self.receipt(), current: Self.modal(.top)))
        #expect(!HiddenScreen.showsRemembered([other], remembered: Self.receipt(), current: Self.otherScreen()))
        #expect(!HiddenScreen.showsRemembered([address], remembered: Self.receipt(), current: Self.receipt()), "text listed now is not the old screen")
    }

    // MARK: - Painting what the cache remembers

    @Test("each modal shape paints the field the cache last saw, reported remembered with one warning", arguments: Shape.allCases)
    func paintsRemembered(shape: Shape) async throws {
        let fixture = try TreeCacheFixture()
        try Self.remember(Self.receipt(), in: fixture)

        let (report, image, err) = try await Self.capture(["--mask-emails"], tree: Self.modal(shape), png: try Self.receiptBehindPNG(), fixture: fixture)

        #expect(Self.fieldPainted(image), "the email field the modal hides was left unpainted")
        #expect(report.maskedBy?[.emails] == 1)
        #expect(report.maskUnproven == "remembered")
        #expect(err.components(separatedBy: "a modal hides an email address from the tree").count == 2, "\(err)")
        #expect(!err.contains(Self.email))
    }

    @Test("a second capture under the same modal paints from the memory the first one kept")
    func secondCapture() async throws {
        let fixture = try TreeCacheFixture()
        try Self.remember(Self.receipt(), in: fixture)
        let first = TreeCacheRecord.committing(
            DeviceActivityLedger.Activity(device: Self.device, tree: Self.modal(.top), treeReadAt: fixture.now),
            previous: try fixture.record(for: Self.device), command: "screenshot", inputAtEnd: false, bootMarker: nil, now: fixture.now, statusBar: 60
        )
        try fixture.write(try #require(first))

        let (report, image, _) = try await Self.capture(["--mask-emails"], tree: Self.modal(.top), png: try Self.receiptBehindPNG(), fixture: fixture)

        #expect(Self.fieldPainted(image))
        #expect(report.maskUnproven == "remembered")
    }

    @Test("--mask-id, --mask-label and --mask-text paint the remembered field, and a missed id is named once")
    func selectorsRemembered() async throws {
        for arguments in [["--mask-id", "mask-sheet-test-email"], ["--mask-label", "Receipt Email"], ["--mask-text", "fixture@"]] {
            let fixture = try TreeCacheFixture()
            try Self.remember(Self.receipt(), in: fixture)
            let (report, image, err) = try await Self.capture(arguments, tree: Self.modal(.tap), png: try Self.png([]), fixture: fixture)

            #expect(Self.fieldPainted(image), "\(arguments)")
            #expect(report.maskUnproven == "remembered", "\(arguments)")
            if arguments[0] == "--mask-id" {
                #expect(report.maskUnmatched == ["--mask-id mask-sheet-test-email"], "the tree matched nothing, which JSON keeps")
                #expect(!err.contains("nothing matched"), "the remembered warning names it instead: \(err)")
            }
        }
    }

    @Test("--mask-skip-beneath leaves a remembered field unpainted, counted as skipped, as it leaves one beneath a page")
    func skipBeneath() async throws {
        let fixture = try TreeCacheFixture()
        try Self.remember(Self.receipt(), in: fixture)
        let (report, image, err) = try await Self.capture(["--mask-emails", "--mask-skip-beneath"], tree: Self.modal(.tap), png: try Self.png([]), fixture: fixture)

        #expect(!Self.fieldPainted(image))
        #expect(report.skippedBeneath?[.emails] == 1)
        #expect(report.maskUnproven != "remembered")
        #expect(!err.contains("tree cache last saw"), "\(err)")
    }

    @Test("a value the cache hid still matches: an email it redacted, a pattern it redacted")
    func redactedValuesMatch() throws {
        let hidden = Self.receipt(Self.field(LogRedactor.emailMarker))
        let found = try RememberedMasks.targets(plan: MaskPlan(emails: true), selected: [], remembered: hidden, current: Self.modal(.tap), region: Self.full)
        #expect(found.frames[.emails] == [Self.fieldFrame])

        let patterned = Self.receipt(Self.field("ref \(LogRedactor.marker)"))
        let text = try RememberedMasks.targets(plan: MaskPlan(texts: ["ABC-\\d+"]), selected: [], remembered: patterned, current: Self.modal(.tap), region: Self.full)
        #expect(text.frames[.text] == [Self.fieldFrame])
        #expect(text.names == ["--mask-text ABC-\\d+"])
    }

    // MARK: - When a memory is stale

    @Test("another app, a turned or resized screen, an old memory and a field listed again elsewhere paint nothing from memory")
    func staleness() async throws {
        let cases: [(String, (TreeCacheFixture) throws -> UITree)] = [
            ("another app", { fixture in try Self.remember(Self.receipt(app: "Other"), in: fixture); return Self.modal(.tap) }),
            ("turned", { fixture in try Self.remember(Self.receipt(width: 844, height: 390), in: fixture); return Self.modal(.tap) }),
            ("unconfirmed, older than 2 minutes", { fixture in
                try Self.remember(Self.receipt(), in: fixture, age: 5, beneath: TreeCacheRecord.Beneath(readAt: fixture.now - 121, roots: Self.receipt().roots), over: Self.modal(.top))
                return Self.modal(.tap)
            }),
            ("confirmed, older than 10 minutes", { fixture in
                try Self.remember(Self.receipt(), in: fixture, age: 5, beneath: TreeCacheRecord.Beneath(readAt: fixture.now - 601, roots: Self.receipt().roots, confirmed: true), over: Self.modal(.top))
                return Self.modal(.tap)
            }),
            ("listed again elsewhere", { fixture in
                try Self.remember(Self.receipt(), in: fixture)
                return Self.modal(.tap, extra: [Self.field("Receipt email", frame: FakeUI.frame(32, 460, 326, 44))])
            }),
        ]
        for (name, setUp) in cases {
            let fixture = try TreeCacheFixture()
            let tree = try setUp(fixture)
            let (report, image, _) = try await Self.capture(["--mask-emails"], tree: tree, png: try Self.png([]), fixture: fixture)
            #expect(!Self.fieldPainted(image), "\(name)")
            #expect(report.maskUnproven != "remembered", "\(name)")
        }
    }

    @Test("a confirmed memory lasts the cache's 10 minutes")
    func confirmedLasts() async throws {
        let fixture = try TreeCacheFixture()
        try Self.remember(Self.receipt(), in: fixture, beneath: TreeCacheRecord.Beneath(readAt: fixture.now - 300, roots: Self.receipt().roots, confirmed: true), over: Self.modal(.tap))
        let (_, image, _) = try await Self.capture(["--mask-emails"], tree: Self.modal(.tap), png: try Self.png([]), fixture: fixture)
        #expect(Self.fieldPainted(image))
    }

    @Test("moving to another screen looks like a modal to the tree: a text read that sees nothing of the old screen paints nothing and drops the memory")
    func navigationIsNoModal() async throws {
        let fixture = try TreeCacheFixture()
        try Self.remember(Self.receipt(), in: fixture)
        let ledger = DeviceActivityLedger(now: { fixture.now })
        let console = ConsoleCapture()
        let backend = FakeDeviceBackend(trees: [Self.otherScreen()], screenshots: [try Self.png([("Tap anywhere to count", 100, 300)])], screen: ScreenshotMaskTests.screen)

        let (report, image, _) = try await DeviceActivityLedger.$current.withValue(ledger) {
            try await TreeCacheEnvironment.$current.withValue(fixture.environment) {
                try await Console.$current.withValue(AgentOutputTests.agentConsole(console)) {
                    try await ScreenshotMaskTests.capture(["--mask-emails"], on: backend)
                }
            }
        }
        let err = console.err

        #expect(!Self.fieldPainted(image))
        #expect(report.maskUnproven == nil, "\(err)")
        #expect(!err.contains("maskUnproven"), "\(err)")
        #expect(ledger.activity(for: Self.device)?.beneathShown == false)
    }

    @Test("with the tree cache off there is no memory: a modal warns and paints nothing it cannot see")
    func cacheOff() async throws {
        let fixture = try TreeCacheFixture()
        try Self.remember(Self.receipt(), in: fixture)
        fixture.cacheOn = false

        let (report, image, err) = try await Self.capture(["--mask-emails"], tree: Self.modal(.tap), png: try Self.png([]), fixture: fixture)

        #expect(!Self.fieldPainted(image))
        #expect(report.maskUnproven == "modal")
        #expect(err.contains("a modal covers the app"), "\(err)")
    }

    // MARK: - Never less than before

    @Test("a memory only adds paint: every pixel the tree and text read paint stays painted, and nothing named drops out", arguments: Shape.allCases)
    func onlyAdds(shape: Shape) throws {
        let capture = try ScreenCapture.make(png: try Self.png([(Self.email, 28, 118), ("Address bc1q...7k3m", 100, 167)]), platform: .ios, screen: ScreenshotMaskTests.screen)
        let tree = Self.modal(shape, extra: [FakeUI.node(.text, id: "shown-mail", label: "help@example.com", frame: FakeUI.frame(40, 600, 200, 20))])
        let plan = MaskPlan(secure: true, ids: ["mask-sheet-test-email"], emails: true)
        let hidden = ScreenCapture.HiddenText(lines: [ScreenTextLine(text: Self.email, frame: FakeUI.frame(28, 118, 200, 20))])
        let memory = RememberedMasks.Found(frames: [.emails: [Self.fieldFrame], .id: [Self.fieldFrame]], names: ["an email address"])

        let without = try ScreenCapture.masking(capture, plan: plan, tree: tree, hidden: hidden)
        let with = try ScreenCapture.masking(capture, plan: plan, tree: tree, hidden: hidden, remembered: .found(memory))

        #expect(with.unmatched == without.unmatched)
        for (kind, count) in without.painted { #expect((with.painted[kind] ?? 0) >= count, "\(kind)") }
        let before = try Self.blackPixels(without.capture.image)
        let after = try Self.blackPixels(with.capture.image)
        #expect(!before.isEmpty)
        #expect(before.isSubset(of: after), "a pixel painted without the memory was left unpainted with it")
        #expect(after.count > before.count)
    }

    // MARK: - Unlisted addresses

    @Test("an address the text read finds that no element holds is painted, warned of in one line and flags the capture")
    func unlistedAddress() async throws {
        let fixture = try TreeCacheFixture()
        fixture.cacheOn = false
        let (report, image, err) = try await Self.capture(["--mask-emails"], tree: Self.modal(.tap), png: try Self.png([(Self.email, 28, 118)]), fixture: fixture)

        #expect(ScreenshotMaskTests.point(image, 60, 126) == ScreenshotMaskTests.black)
        #expect(report.maskUnproven == "modal")
        #expect(err.components(separatedBy: "an email address shows behind a modal that no element in the tree holds").count == 2, "\(err)")
        #expect(!err.contains("a modal covers the app"), "\(err)")
    }

    // MARK: - Cost

    @Test("a capture with no modal reads no tree cache and no text")
    func noModalNoCost() async throws {
        let fixture = try TreeCacheFixture()
        try Self.remember(Self.receipt(), in: fixture)
        let reads = ReadCount()
        let directory = fixture.directory
        let counting = TreeCacheEnvironment(directory: { reads.bump(); return directory }, cacheOn: true, now: { fixture.now }, sleep: { _ in })
        let capture = try ScreenCapture.make(png: try Self.png([]), platform: .ios, screen: ScreenshotMaskTests.screen)

        let behind = await ScreenCapture.behindModal(Self.receipt(), plan: MaskPlan(emails: true), screen: nil, device: Self.device, backend: FakeDeviceBackend(trees: []), environment: counting)

        #expect(behind == nil)
        #expect(reads.count == 0)
        #expect(await ScreenCapture.hiddenText(in: capture, behind: behind, tree: Self.receipt(), plan: MaskPlan(emails: true)) == nil)
    }

    // MARK: - The tree cache keeps what a modal hides

    @Test("a modal read keeps the last read without one; another modal read carries it; a read without a modal, or a text read that saw nothing, drops it")
    func carry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func commit(_ tree: UITree?, after previous: TreeCacheRecord?, shown: Bool? = nil, input: Bool = false) -> TreeCacheRecord? {
            var activity = DeviceActivityLedger.Activity(device: Self.device, tree: tree, treeReadAt: tree == nil ? nil : now, lastInputAt: input ? now : nil)
            activity.beneathShown = shown
            return TreeCacheRecord.committing(activity, previous: previous, command: "screenshot", inputAtEnd: input, bootMarker: nil, now: now, statusBar: 60)
        }
        let screen = try #require(commit(Self.receipt(), after: nil))
        #expect(screen.beneath == nil)

        let top = try #require(commit(Self.modal(.top), after: screen))
        #expect(top.beneath?.roots == Self.receipt().roots)
        #expect(top.beneath?.confirmed == false, "a modal told by memory alone waits for a text read")
        #expect(commit(Self.modal(.tap), after: screen)?.beneath?.confirmed == true, "a tappable backdrop confirms itself")
        #expect(commit(Self.modal(.top), after: top, shown: true)?.beneath?.confirmed == true)
        #expect(commit(Self.modal(.top), after: top)?.beneath?.roots == Self.receipt().roots)
        #expect(commit(Self.modal(.top), after: top, shown: false)?.beneath == nil)
        #expect(commit(Self.receipt(), after: top)?.beneath == nil)
        #expect(commit(nil, after: top, input: true)?.beneath?.roots == Self.receipt().roots, "input with no read keeps it")

        let other = try #require(commit(Self.receipt(app: "Other"), after: nil))
        #expect(commit(Self.modal(.top), after: other)?.beneath == nil, "another app's screen is not what this modal hides")

        let decoded = try TreeCacheRecord(data: try #require(commit(Self.modal(.tap), after: screen)).encoded())
        #expect(decoded.beneath?.confirmed == true)
        #expect(decoded.beneath?.roots.first?.flattened().contains { $0.id == "mask-sheet-test-email" } == true)
    }

    // MARK: - Runs and video

    @Test("an evidence run's manifest line and timeline name why masks could not prove the capture")
    func runFlags() {
        let line = RunManifestLine(n: 1, file: "001.png", command: "screenshot", time: Date(timeIntervalSince1970: 0), ms: 10, exit: 0, masked: 1, maskUnproven: "remembered")
        #expect(line.jsonLine(timeZone: TimeZone(identifier: "UTC")!).contains(#""maskUnproven":"remembered""#))
        let timeline = RunTimeline(dir: "/tmp/run", state: RunState(label: "modal", startedAt: Date(timeIntervalSince1970: 0), masks: .defaults), entries: [line], unrecorded: [])
        #expect(timeline.text(now: Date(timeIntervalSince1970: 60), timeZone: TimeZone(identifier: "UTC")!).contains("unproven remembered"))
    }

    @Test("video will not start while the cache remembers, behind a modal, what the mask file masks")
    func videoRefuses() async throws {
        let fixture = try TreeCacheFixture()
        try Self.remember(Self.receipt(), in: fixture)
        let config = MaskConfigs.Loaded(config: MaskConfig(ids: ["mask-sheet-test-email"]), path: "/tmp/offsider.mask.json")
        let backend = FakeDeviceBackend(trees: [Self.modal(.tap)])

        await #expect(throws: CLIError.self) {
            try await fixture.run {
                try await MaskConfigs.$source.withValue({ config }) {
                    try await Console.$current.withValue(AgentOutputTests.agentConsole(ConsoleCapture())) {
                        try await VideoMaskOptions.requireNoSecureField(command: "record-video", backend: backend, device: Self.device)
                    }
                }
            }
        }
    }
}

/// Counts calls from a `@Sendable` closure.
private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}
