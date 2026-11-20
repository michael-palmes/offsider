import CoreGraphics
import CoreText
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// An iOS sheet that hides the screen beneath it from accessibility, while that screen stays drawn, dimmed.
@Suite("Masks behind an iOS sheet", .personOutput)
@MainActor
struct MaskBehindSheetTests {
    nonisolated static let email = "sam.fixture@example.com"
    nonisolated static let sheetTitle = FakeUI.node(.header, id: "mask-sheet-test-root-title", label: "Receipt Details", frame: FakeUI.frame(16, 564, 358, 44))
    nonisolated static let sheetClose = FakeUI.node(.button, id: "mask-sheet-test-root-close", label: "Close Root Sheet", frame: FakeUI.frame(111, 659, 168, 44))
    nonisolated static let sheet = FakeUI.node(.group, frame: FakeUI.frame(0, 548, 390, 296), children: [sheetTitle, sheetClose])
    nonisolated static let backdrop = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 390, 844))

    /// The root sheet: nothing of the screen beneath is listed, header included.
    nonisolated static func rootSheet(platform: DevicePlatform = .ios) -> UITree {
        FakeUI.tree(platform: platform, width: 390, height: 844, [FakeUI.node(.group, frame: FakeUI.frame(0, 0, 390, 844), children: [backdrop, sheet])])
    }

    /// The same screen with no sheet: what the hidden screen lists when it shows.
    nonisolated static func openScreen() -> UITree {
        FakeUI.tree(width: 390, height: 844, [
            backdrop,
            FakeUI.node(.button, id: "BackButton", label: "Offsider Playground", frame: FakeUI.frame(8, 47, 44, 44)),
            FakeUI.node(.header, id: "mask-sheet-test-screen", label: "Mask Sheet", frame: FakeUI.frame(60, 59, 270, 20)),
            FakeUI.node(.textField, id: "mask-sheet-test-email", label: "Receipt Email", value: email, frame: FakeUI.frame(16, 107, 358, 44)),
            FakeUI.node(.text, id: "mask-sheet-test-address", label: "Address bc1q...7k3m", frame: FakeUI.frame(100, 167, 200, 20)),
        ])
    }

    /// A white capture with dimmed text where the hidden screen draws it, and the sheet's own title.
    static func sheetPNG() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 1170, height: 2532, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1170, height: 2532))
        let font = CTFontCreateWithName("Helvetica" as CFString, 51, nil)
        for (text, x, y) in [(email, 28.0, 118.0), ("Address bc1q...7k3m", 100.0, 167.0), ("Receipt Details", 130.0, 575.0)] {
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.35, alpha: 1)]
            context.textPosition = CGPoint(x: x * 3, y: 2532 - (y + 14) * 3)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        return try ScreenImage.encode(try #require(context.makeImage()), as: .png)
    }

    /// The modal a capture of `tree` finds with no tree cache to remember from.
    nonisolated static func behind(_ tree: UITree) -> ScreenCapture.BehindModal? {
        HiddenScreen.modal(in: tree, belowStatusBar: 60).map { ScreenCapture.BehindModal(modal: $0, remembered: nil, cacheOff: false) }
    }

    static func backend(_ tree: UITree) throws -> FakeDeviceBackend {
        FakeDeviceBackend(trees: [tree], screenshots: [try sheetPNG()], screen: ScreenshotMaskTests.screen)
    }

    static func agentCapture(
        _ arguments: [String], tree: UITree = rootSheet(), environment: [String: String] = ["OFFSIDER_MASK_SECURE": "0"]
    ) async throws -> (report: ScreenshotReport, image: CGImage, err: String) {
        let capture = ConsoleCapture()
        let backend = try backend(tree)
        let (report, image, _) = try await Console.$current.withValue(AgentOutputTests.agentConsole(capture)) {
            try await ScreenshotMaskTests.capture(arguments, on: backend, environment: environment)
        }
        return (report, image, capture.err)
    }

    // MARK: - Where a backdrop hides the screen

    @Test("a backdrop over a band the tree lists nothing in is a hidden screen, below the status bar")
    func rootSheetRegion() {
        #expect(HiddenScreen.region(in: Self.rootSheet(), belowStatusBar: 60) == FakeUI.frame(0, 60, 390, 784))
    }

    @Test("a labelled backdrop below a listed header hides the screen between them")
    func hidingSheetRegion() {
        let dismiss = FakeUI.node(.other, label: "Dismiss", frame: FakeUI.frame(0, 91, 390, 753))
        let tree = FakeUI.tree(width: 390, height: 844, [
            FakeUI.node(.header, id: "mask-sheet-test-screen", label: "Mask Sheet", frame: FakeUI.frame(60, 59, 270, 20)),
            dismiss, Self.sheet,
        ])
        #expect(HiddenScreen.region(in: tree, belowStatusBar: 60) == FakeUI.frame(0, 91, 390, 753))
    }

    @Test("a screen that lists its own content, a sheet over a listed screen, and Android are not hidden")
    func listedScreens() {
        #expect(HiddenScreen.region(in: Self.openScreen(), belowStatusBar: 60) == nil)
        var modal = Self.openScreen()
        modal.roots[0].children += [FakeUI.node(.other, label: "Dismiss", frame: FakeUI.frame(0, 0, 390, 844)), Self.sheet]
        #expect(HiddenScreen.region(in: modal, belowStatusBar: 60) == nil)
        #expect(HiddenScreen.region(in: Self.rootSheet(platform: .android), belowStatusBar: 60) == nil)
        #expect(HiddenScreen.region(in: FakeUI.tree(width: 390, height: 844, [Self.backdrop]), belowStatusBar: 60) == nil)
        for role in [UIRole.image, .scrollView] {
            let full = FakeUI.node(role, frame: FakeUI.frame(0, 0, 390, 844))
            #expect(HiddenScreen.region(in: FakeUI.tree(width: 390, height: 844, [full, Self.sheet]), belowStatusBar: 60) == nil, "\(role)")
        }
    }

    @Test("in landscape the band starts at the top, as no status bar is drawn")
    func landscapeRegion() {
        let sheet = FakeUI.node(.group, frame: FakeUI.frame(0, 250, 844, 140), children: [FakeUI.node(.button, label: "Close Root Sheet", frame: FakeUI.frame(338, 300, 168, 44))])
        let tree = FakeUI.tree(width: 844, height: 390, [FakeUI.node(.group, frame: FakeUI.frame(0, 0, 844, 390)), sheet])
        #expect(HiddenScreen.region(in: tree, belowStatusBar: 60) == FakeUI.frame(0, 0, 844, 390))
    }

    @Test("text the tree lists, the keyboard's keys and stray marks are not hidden text")
    func unlistedLines() {
        var tree = Self.rootSheet()
        tree.roots.append(FakeUI.node(.keyboard, frame: FakeUI.frame(0, 600, 390, 244)))
        let lines = [
            ScreenTextLine(text: Self.email, frame: FakeUI.frame(28, 118, 200, 20)),
            ScreenTextLine(text: "Receipt Details", frame: FakeUI.frame(130, 575, 120, 20)),
            ScreenTextLine(text: "Q W E", frame: FakeUI.frame(10, 700, 100, 20)),
            ScreenTextLine(text: "·", frame: FakeUI.frame(10, 300, 5, 5)),
        ]
        #expect(HiddenScreen.unlisted(lines, in: tree).map(\.text) == [Self.email])
    }

    @Test("hidden lines are painted whole for emails and text patterns, naming the patterns they meet")
    func hiddenTargets() throws {
        let lines = [
            ScreenTextLine(text: "Receipt to \(Self.email)", frame: FakeUI.frame(28, 118, 300, 20)),
            ScreenTextLine(text: "Address bc1q...7k3m", frame: FakeUI.frame(100, 167, 200, 20)),
        ]
        let found = try HiddenScreen.targets(lines, plan: MaskPlan(texts: [#"\.\.\."#, "never"], emails: true))
        #expect(found.frames[.emails] == [FakeUI.frame(28, 118, 300, 20)])
        #expect(found.frames[.text] == [FakeUI.frame(100, 167, 200, 20)])
        #expect(found.matched == [#"\.\.\."#])
        #expect(try HiddenScreen.targets(lines, plan: MaskPlan(secure: true)).frames.isEmpty)
    }

    // MARK: - Screenshots

    @Test("an email drawn behind the sheet is painted, and the capture says masks could not prove it")
    func emailsBehindSheet() async throws {
        let (report, image, err) = try await Self.agentCapture(["--mask-emails"])

        #expect(report.maskedBy?[.emails] == 1)
        #expect(report.maskUnproven == "modal")
        #expect(report.jsonLine().contains(#""maskUnproven":"modal""#))
        #expect(ScreenshotMaskTests.point(image, 100, 126) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.point(image, 200, 590) != ScreenshotMaskTests.black, "the sheet's own title was painted")
        #expect(err.contains("an email address shows behind a modal that no element in the tree holds") && err.contains("check the image") && err.contains("(maskUnproven)"), "\(err)")
        #expect(!err.contains("a modal covers the app"), "one warning names the address, not two: \(err)")
        #expect(!err.contains(Self.email))
    }

    @Test("a text pattern matched only behind the sheet is painted and not reported unmatched")
    func textBehindSheet() async throws {
        let (report, image, err) = try await Self.agentCapture(["--mask-text", "bc1q"])

        #expect(report.maskedBy?[.text] == 1)
        #expect(report.maskUnmatched.isEmpty)
        #expect(report.maskUnproven == "modal")
        #expect(ScreenshotMaskTests.point(image, 200, 175) == ScreenshotMaskTests.black)
        #expect(!err.contains("nothing matched"), "\(err)")
    }

    @Test("a read that could not finish leaves the capture unproven; a screen with no backdrop is never read")
    func unreadHiddenText() async throws {
        let capture = try ScreenCapture.make(png: try Self.sheetPNG(), platform: .ios, screen: ScreenshotMaskTests.screen)
        let result = try ScreenCapture.masking(capture, plan: MaskPlan(emails: true), tree: Self.rootSheet(), hidden: ScreenCapture.HiddenText(unread: true))
        #expect(result.unproven == "modal")
        let plan = MaskPlan(emails: true)
        #expect(await ScreenCapture.hiddenText(in: capture, behind: Self.behind(Self.openScreen()), tree: Self.openScreen(), plan: plan) == nil)
        #expect(await ScreenCapture.hiddenText(in: capture, behind: Self.behind(Self.rootSheet()), tree: Self.rootSheet(), plan: plan)?.lines.map(\.text).contains(Self.email) == true)
    }

    @Test("password masks alone still report the hidden screen unproven, painting nothing")
    func secureBehindSheet() async throws {
        let (report, _, err) = try await Self.agentCapture([], environment: [:])

        #expect(report.maskedBy == [.secure: 0])
        #expect(report.maskUnproven == "modal")
        #expect(err.contains("(maskUnproven)"), "\(err)")
    }

    @Test("a mask rule's value pattern paints behind the sheet too")
    func maskRuleBehindSheet() async throws {
        let loaded = MaskConfigs.Loaded(config: MaskConfig(valuePatterns: ["bc1q"]), path: "/repo/offsider.mask.json")
        let (report, image, _) = try await MaskConfigs.$source.withValue({ loaded }) {
            try await Self.agentCapture([])
        }

        #expect(report.maskedBy?[.text] == 1)
        #expect(report.maskUnproven == "modal")
        #expect(ScreenshotMaskTests.point(image, 200, 175) == ScreenshotMaskTests.black)
    }

    @Test("a person reads a one-line warning to check the image")
    func personWarning() async throws {
        let capture = ConsoleCapture()
        let backend = try Self.backend(Self.rootSheet())
        _ = try await Console.$current.withValue(capture.console(out: .person(), err: .person())) {
            try await ScreenshotMaskTests.capture(["--mask-emails"], on: backend)
        }
        #expect(capture.err.contains("An email address shows that the tree does not list; check the image"), "\(capture.err)")
        #expect(!capture.err.contains("maskUnproven"))
    }

    @Test("the same screen with no sheet is masked from the tree and stays proven")
    func openScreenProven() async throws {
        let (report, image, err) = try await Self.agentCapture(["--mask-emails"], tree: Self.openScreen())

        #expect(report.maskedBy?[.emails] == 1)
        #expect(report.maskUnproven == nil)
        #expect(ScreenshotMaskTests.point(image, 100, 126) == ScreenshotMaskTests.black)
        #expect(!err.contains("maskUnproven"), "\(err)")
    }

    @Test("an evidence run keeps the painted capture and its count, warning as on Android")
    func runBehindSheet() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start(masks: RunMasks(emails: true))
        let backend = try Self.backend(Self.rootSheet())
        let capture = ConsoleCapture()
        var report: ScreenshotReport?
        try await Console.$current.withValue(AgentOutputTests.agentConsole(capture)) {
            try await fixture.command(fixture.recorder("screenshot")) { report = try await RunTests.screenshot([], on: backend) }
        }

        #expect(report?.maskUnproven == "modal")
        #expect(report?.runFile != nil)
        #expect(fixture.manifest().map(\.masked) == [1])
        #expect(capture.err.contains("(maskUnproven)"), "\(capture.err)")
    }

    @Test("video warns at the start when a backdrop hides the screen")
    func videoBehindSheet() async throws {
        let capture = ConsoleCapture()
        try await Console.$current.withValue(AgentOutputTests.agentConsole(capture)) {
            try await VideoMaskOptions.requireNoSecureField(command: "record-video", backend: FakeDeviceBackend(trees: [Self.rootSheet()]), device: ScreenshotMaskTests.device)
        }
        #expect(capture.err.contains("(maskUnproven)") && capture.err.contains("the video"), "\(capture.err)")
    }
}
