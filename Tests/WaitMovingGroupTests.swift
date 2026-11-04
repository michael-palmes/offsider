import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A timed-out `--settled` wait names what kept moving, and what it prints lets the next wait pass, on a screen with a save button that stays still.
@Suite("Wait moving group")
@MainActor
struct WaitMovingGroupTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let save = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 700, 350, 44))
    static let width = 402.0, height = 874.0

    /// Sixty reads, then the same again from where they stopped, so a flag has to hold past what its wait saw.
    private static func reads(_ tree: (Int) -> UITree) -> [UITree] { (0..<120).map(tree) }

    private static func screen(_ nodes: [UINode]) -> UITree {
        FakeUI.tree(width: width, height: height, nodes + [save])
    }

    private static func group(id: String? = nil, label: String? = nil, _ frame: UIFrame, children: [UINode] = []) -> UINode {
        var node = FakeUI.node(.other, id: id, label: label, frame: frame)
        node.children = children
        return node
    }

    private static func timedOut(_ trees: [UITree], _ arguments: [String] = []) async throws -> (Wait, WaitOutcome) {
        let wait = try Wait.parse(["--settled", "--ignore-values", "--timeout", "1", "--device", device.rawValue, "--poll-interval", "0.05"] + arguments)
        let outcome = try await wait.evaluate(on: DeviceRouter.Route(backend: FakeDeviceBackend(trees: trees), device: device), logger: OffsiderLogger(), clock: ScriptedClock().poll)
        return (wait, outcome)
    }

    /// Pastes the printed flags, as a person or agent would, into a new wait on reads that carry on from those it saw.
    private static func flagSettles(_ flag: String, on trees: [UITree]) async throws -> Bool {
        try await timedOut(Array(trees.dropFirst(20)), flag.split(separator: " ").map(String.init)).1.met
    }

    @Test("a wide strip running off the screen is left out by a region the parser accepts, as it carries on moving")
    func wideStrip() async throws {
        let trees = Self.reads { Self.screen([Self.group(FakeUI.frame(Double(-40 * $0), 150, 5000, 36))]) }
        let (wait, outcome) = try await Self.timedOut(trees)
        #expect(!outcome.met)
        let flag = try #require(outcome.movingPart?.flag)
        #expect(flag.hasPrefix("--ignore-region"))
        #expect(outcome.reason.contains("moving: other (-800, 150) 5000x36"))
        #expect(wait.failureLine(outcome).contains("add \(flag) to leave it out."))
        #expect(try await Self.flagSettles(flag, on: trees))
    }

    @Test("a group wholly off screen is named as that and left out, past either edge", arguments: [
        (x: 900.0, flag: "--ignore-region 900,"),
        (x: -600.0, flag: "--ignore-region=-"),
    ])
    func offScreen(start: (x: Double, flag: String)) async throws {
        let trees = Self.reads { Self.screen([Self.group(FakeUI.frame(start.x + Double($0 % 8), 100, 300, 40))]) }
        let (_, outcome) = try await Self.timedOut(trees)
        #expect(outcome.reason.contains(", off screen"))
        #expect(outcome.movingUnseen)
        let flag = try #require(outcome.movingPart?.flag)
        #expect(flag.hasPrefix(start.flag))
        #expect(try await Self.flagSettles(flag, on: trees))
    }

    @Test("a screen beneath the page, as big as the page, is left out by its id and the page still counts")
    func beneathByID() async throws {
        let page = Self.group(id: "top-page", FakeUI.frame(0, 0, Self.width, Self.height), children: [Self.save])
        let tree = { (tick: Int) -> UITree in
            let moving = Self.group(FakeUI.frame(Double(tick % 8), 0, 40, 40))
            return FakeUI.tree(width: Self.width, height: Self.height, [Self.group(id: "under-page", FakeUI.frame(0, 0, Self.width, Self.height), children: [moving]), page])
        }
        let trees = Self.reads(tree)
        let (_, outcome) = try await Self.timedOut(trees)
        #expect(outcome.reason.contains("beneath top-page"))
        #expect(outcome.movingUnseen)
        #expect(outcome.movingPart == .id("under-page"))
        #expect(try await Self.flagSettles("--ignore-id under-page", on: trees))
    }

    @Test("a nameless screen beneath the page offers no flag that would take the page too, and says the pixels can pass")
    func beneathWithNoID() async throws {
        let page = Self.group(id: "top-page", FakeUI.frame(0, 0, Self.width, Self.height), children: [Self.save])
        let trees = Self.reads { tick in
            FakeUI.tree(width: Self.width, height: Self.height, [Self.group(FakeUI.frame(0, Double(tick % 8), Self.width, Self.height)), page])
        }
        let (wait, outcome) = try await Self.timedOut(trees)
        #expect(outcome.movingPart == nil)
        #expect(outcome.reason.contains("beneath top-page"))
        #expect(wait.failureLine(outcome).contains("--settle-by screen"))
        #expect(WaitReport(outcome).jsonLine().contains("\"leaveOut\":null"))
    }

    @Test("movers at both ends of the screen each get a flag, since one rectangle would take the screen, and together they settle it")
    func twoEnds() async throws {
        let trees = Self.reads { tick in
            let offset = Double(tick % 8)
            return Self.screen([
                Self.group(FakeUI.frame(offset, 10, 300, 40)),
                Self.group(id: "footer-strip", FakeUI.frame(offset, 800, 300, 40)),
            ])
        }
        let (_, outcome) = try await Self.timedOut(trees)
        let flag = try #require(outcome.movingPart?.flag)
        #expect(flag.contains("--ignore-region") && flag.contains("--ignore-id footer-strip"))
        #expect(outcome.reason.contains("footer-strip ("))
        #expect(try await Self.flagSettles(flag, on: trees))
    }

    @Test("movers inside one page with an id each get their own flag, as the page's id would leave nothing")
    func twoEndsInAPage() async throws {
        let trees = Self.reads { tick in
            let offset = Double(tick % 8)
            let page = Self.group(id: "main", FakeUI.frame(0, 0, Self.width, Self.height), children: [
                Self.group(FakeUI.frame(offset, 10, 300, 40)),
                Self.group(FakeUI.frame(offset, 800, 300, 40)),
                Self.save,
            ])
            return FakeUI.tree(width: Self.width, height: Self.height, [page])
        }
        let (_, outcome) = try await Self.timedOut(trees)
        let flag = try #require(outcome.movingPart?.flag)
        #expect(!flag.contains("main"))
        #expect(flag.components(separatedBy: "--ignore-region").count == 3)
        #expect(try await Self.flagSettles(flag, on: trees))
    }

    @Test("a page sliding between a small header and footer offers no flag, though the two span the screen")
    func pageBetweenBars() async throws {
        let trees = Self.reads { tick in
            FakeUI.tree(width: Self.width, height: Self.height, [
                Self.group(id: "header", FakeUI.frame(0, 0, Self.width, 50)),
                Self.group(id: "main", FakeUI.frame(0, Double(50 + tick % 8), Self.width, 774)),
                Self.group(id: "footer", FakeUI.frame(0, 824, Self.width, 50)),
            ])
        }
        #expect(try await Self.timedOut(trees).1.movingPart == nil)
    }

    @Test("a visible element that keeps coming and going is not called unseen")
    func comesAndGoes() async throws {
        let toast = Self.group(id: "toast", FakeUI.frame(0, 0, Self.width, Self.height))
        let trees = Self.reads { tick in
            FakeUI.tree(width: Self.width, height: Self.height, tick % 2 == 0 ? [toast] : [Self.group(FakeUI.frame(0, 0, 10, 10))])
        }
        let (wait, outcome) = try await Self.timedOut(trees)
        #expect(!outcome.movingUnseen)
        #expect(!wait.failureLine(outcome).contains("--settle-by screen"))
    }

    @Test("a visible page sliding under a small bar offers no flag, since nothing worth waiting for would be left, and no pixel advice")
    func wholePageMoves() async throws {
        let bar = Self.group(id: "bar", FakeUI.frame(0, 0, Self.width, 50))
        let trees = Self.reads { tick in
            FakeUI.tree(width: Self.width, height: Self.height, [Self.group(id: "main", FakeUI.frame(0, Double(50 + tick % 8), Self.width, 824)), bar])
        }
        let (wait, outcome) = try await Self.timedOut(trees)
        #expect(outcome.movingPart == nil)
        #expect(!outcome.movingUnseen)
        #expect(outcome.reason.contains("moving: main ("))
        #expect(wait.failureLine(outcome).contains("No flag leaves it out"))
        #expect(!wait.failureLine(outcome).contains("--settle-by screen"))
    }

    @Test("a masked element's text stays out of the reason, and its id out of the flag")
    func masked() async throws {
        let mask = TreeValueMask(ids: ["secret-panel"])
        let trees = Self.reads { Self.screen([Self.group(id: "secret-panel", label: "Code 123", FakeUI.frame(20, Double(100 + $0 % 8), 300, 200))]) }
        try await OutputMasks.$current.withValue(OutputMasks { mask }) {
            let (_, outcome) = try await Self.timedOut(trees)
            #expect(outcome.movingPart?.flag.contains("secret-panel") == false)
            #expect(!Wait.shown(outcome, mask: mask).reason.contains("Code 123"))
        }
    }

    @Test("--ignore-region takes an off-screen origin, and --region and --mask-region still refuse one")
    func negativeOrigin() throws {
        #expect(try Wait.parse(["--settled", "--ignore-region=-600,0,300,40", "--device", Self.device.rawValue]).leaveOut().regions == [PointRegion(x: -600, y: 0, width: 300, height: 40)])
        #expect(throws: (any Error).self) { try PointRegion.parse("-600,0,300,40") }
        #expect(throws: (any Error).self) { try PointRegion.parse("-600,0,300,40", option: "--mask-region") }
    }

    @Test("an off-screen region's pixels are no trouble with --settle-by both")
    func offScreenPixels() async throws {
        let shot = try ScreenImage.encode(TestImages.make(width: 40, height: 40, marked: []), as: .png)
        let screen = UIScreenInfo(width: 40, height: 40, scale: 1, rotationDegrees: 0)
        let tree = FakeUI.tree(width: 40, height: 40, [FakeUI.node(.button, id: "save", frame: FakeUI.frame(0, 20, 40, 20))])
        let wait = try Wait.parse(["--settled", "--settle-by", "both", "--ignore-region=-600,0,300,40", "--timeout", "1", "--device", Self.device.rawValue, "--poll-interval", "0.05"])
        let backend = FakeDeviceBackend(trees: [tree], screenshots: [shot, shot, shot, shot], screen: screen)
        let outcome = try await wait.evaluate(on: DeviceRouter.Route(backend: backend, device: Self.device), logger: OffsiderLogger(), clock: ScriptedClock().poll)
        #expect(outcome.met)
    }
}
