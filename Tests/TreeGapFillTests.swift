import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A plain read that leaves out what `hidden` holds, as an app's hidden tab does, and counts what a fill costs.
@MainActor
private final class GapBackend: FakeDeviceBackend, TreeGapFilling {
    let hidden: [UINode]
    private(set) var fills = 0

    init(plain: UITree, hidden: [UINode]) {
        self.hidden = hidden
        super.init(platform: plain.platform, trees: [plain], screenshots: [], screen: UIScreenInfo(width: 390, height: 844))
    }

    func startGapSamples(on id: DeviceID) async -> GapSamples? { nil }

    func fillingGaps(in tree: UITree, on id: DeviceID, samples: GapSamples?) async -> UITree {
        fills += 1
        var filled = tree
        filled.roots[0].children.insert(contentsOf: hidden, at: 0)
        filled.filledFromGaps = hidden.count
        return filled
    }
}

@Suite("Filling what an app hides from accessibility")
@MainActor
struct TreeGapFillTests {
    static let host = 700
    static let back = node(.button, id: "back", label: "Back", y: 50)
    static let homeTab = node(.button, id: "tab-home", label: "Home Tab", y: 795)
    static let plain = iosTree([back, homeTab])

    static func node(_ role: UIRole, id: String? = nil, label: String? = nil, value: String? = nil, y: Double, height: Double = 49, pid: Int = host) -> UINode {
        FakeUI.node(role, id: id, label: label, value: value, frame: FakeUI.frame(0, y, 390, height), pid: pid)
    }

    static func row(_ number: Int, pid: Int = host) -> UINode {
        node(.button, id: "row-\(number)", label: "Saved Item \(number)", y: 100 + Double(number) * 56, height: 56, pid: pid)
    }

    static func iosTree(_ children: [UINode]) -> UITree {
        UITree(platform: .ios, device: "d", roots: [FakeUI.node(.application, label: "Playground", frame: FakeUI.frame(0, 0, 390, 844), pid: host, children: children)])
    }

    /// What a point read answers: the hidden row under the point, else `behind`.
    static func answers(_ rows: [UINode], behind: UINode? = nil) -> (UIPoint) -> UINode? {
        { point in rows.first { $0.frame?.contains(point) == true } ?? behind }
    }

    /// Fills `tree` from point reads answering `answer`, returning the tree, how many sample points were read and how many points were read after them.
    static func fill(
        _ tree: UITree,
        answer: (UIPoint) -> UINode?,
        now: () -> TimeInterval = { 0 }
    ) async -> (tree: UITree, samples: Int, reads: Int) {
        let points = TreeGapFill.samplePoints(in: FakeUI.frame(0, 0, 390, 844))
        var samples = 0
        var reads = 0
        let filled = await TreeGapFill.filling(tree, points: points, samples: { wanted, _ in
            samples = wanted.filter { $0 }.count
            return zip(points, wanted).map { $1 ? answer($0) : nil }
        }, read: { points, _ in
            reads += points.count
            return points.map(answer)
        }, now: now)
        return (filled, samples, reads)
    }

    static func ids(_ tree: UITree) -> Set<String> {
        Set(tree.roots.flatMap { $0.flattened() }.compactMap(\.id))
    }

    @Test("a screen whose samples answer only with what the tree lists costs no more reads")
    func listedScreenCostsNothing() async {
        let page = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 390, 844), pid: Self.host)
        let (filled, _, reads) = await Self.fill(Self.plain, answer: Self.answers([Self.back, Self.homeTab], behind: page))
        #expect(filled == Self.plain)
        #expect(filled.filledFromGaps == nil)
        #expect(reads == 0)
    }

    @Test("white space answering with an unlabelled group or the app itself starts no scan")
    func whiteSpaceCostsNothing() async {
        let group = FakeUI.node(.group, frame: FakeUI.frame(0, 100, 390, 200), pid: Self.host)
        let app = FakeUI.node(.application, label: "Playground", frame: FakeUI.frame(0, 0, 390, 844), pid: Self.host)
        #expect(await Self.fill(Self.plain, answer: { $0.y < 400 ? group : app }).reads == 0)
    }

    @Test("rows found at points are listed once each, in reading order, beneath the tree's own")
    func rowsAreListed() async {
        let rows = (1...10).map { Self.row($0) }
        let (filled, _, reads) = await Self.fill(Self.plain, answer: Self.answers(rows))

        #expect(filled.filledFromGaps == 10)
        #expect(reads > 0)
        let children = filled.roots[0].children
        #expect(children.prefix(10).map(\.id) == rows.map(\.id))
        #expect(children.suffix(2).map(\.id) == ["back", "tab-home"])
        #expect(filled.context.headerLines.contains("# filled: 10 elements the app hides from accessibility"))
    }

    @Test("a screen the tree covers reads no sample at all")
    func coveredScreenReadsNothing() async {
        let wall = (0..<9).flatMap { row in
            (0..<3).map { column in
                FakeUI.node(.button, id: "w\(row)-\(column)", label: "W\(row)\(column)", frame: FakeUI.frame(Double(column) * 130, Double(row) * 94, 130, 94), pid: Self.host)
            }
        }
        let (_, samples, reads) = await Self.fill(Self.iosTree(wall), answer: { _ in Issue.record("no point should be read"); return nil })
        #expect(samples == 0 && reads == 0)
    }

    @Test("when every sample's hit-test failed, the points are read once more before the screen counts as white space")
    func failedSamplesAreReadAgain() async {
        let row = Self.row(3)
        let points = TreeGapFill.samplePoints(in: FakeUI.frame(0, 0, 390, 844))
        var rounds = 0
        let filled = await TreeGapFill.filling(Self.plain, points: points, samples: { wanted, _ in
            wanted.map { _ in nil }
        }, read: { points, _ in
            rounds += 1
            return points.map { row.frame?.contains($0) == true ? row : nil }
        }, now: { 0 })
        #expect(filled.filledFromGaps == 1)
        #expect(rounds >= 2)
    }

    @Test("a listed element's own text, and another process's view, are not content the tree missed")
    func ownTextAndForeignHits() async {
        let listedRow = Self.node(.button, id: "row", label: "Listed Row", y: 200, height: 56)
        let ownText = FakeUI.node(.text, label: "Listed Row", frame: FakeUI.frame(16, 218, 100, 20), pid: Self.host)
        let glyph = FakeUI.node(.text, label: ">", frame: FakeUI.frame(360, 218, 10, 20), pid: Self.host)
        let foreign = Self.node(.button, id: "prompt-allow", label: "Allow", y: 400, height: 56, pid: 900)
        let tree = Self.iosTree([Self.back, listedRow, Self.homeTab])
        let (filled, _, reads) = await Self.fill(tree) { point in
            if point.y > 400 && point.y < 456 { return foreign }
            return point.x < 100 ? ownText : glyph
        }
        #expect(filled == tree)
        #expect(reads == 0)
    }

    @Test("a fill stops at its read limit and its time limit, keeping what it found")
    func limits() async {
        let rows = (1...12).map { Self.row($0) }
        // Every point read also finds a new element, so only the limits can stop it.
        var serial = 0
        let endless: (UIPoint) -> UINode? = { point in
            serial += 1
            return FakeUI.node(.button, id: "e\(serial)", label: "E\(serial)", frame: FakeUI.frame(point.x, point.y, 1, 1), pid: Self.host)
        }
        #expect(await Self.fill(Self.plain, answer: endless).reads <= TreeGapFill.readLimit)

        var clock: TimeInterval = 0
        let (filled, _, reads) = await Self.fill(Self.plain, answer: Self.answers(rows), now: {
            clock += TreeGapFill.timeLimit
            return clock
        })
        #expect(reads == 0)
        #expect(filled.filledFromGaps ?? 0 > 0)
    }

    @Test("what a fill adds goes through the same masks as any other node")
    func masks() async throws {
        let passcode = FakeUI.node(.secureTextField, id: "passcode", label: "Passcode", value: "4821-fixture", frame: FakeUI.frame(0, 240, 390, 50), pid: Self.host)
        let number = FakeUI.node(.text, id: "account", label: "Item Number 4821", frame: FakeUI.frame(0, 350, 390, 40), pid: Self.host)
        let (filled, _, _) = await Self.fill(Self.plain, answer: Self.answers([passcode, number]))
        var mask = TreeValueMask.none
        mask.ids = ["account", "passcode"]

        let shown = filled.redacted(mask).roots[0].children
        let passcodeShown = try #require(shown.first { $0.id == "passcode" })
        let accountShown = try #require(shown.first { $0.id == "account" })
        #expect(passcodeShown.value?.contains("4821") != true)
        #expect(accountShown.label?.contains("4821") != true)
    }

    @Test("a password field a fill finds is remembered by place only, so showing it later still masks it")
    func filledPasswordIsRemembered() throws {
        let frame = FakeUI.frame(0, 240, 390, 50)
        let secure = FakeUI.node(.secureTextField, id: "passcode", value: "••••", frame: frame, pid: Self.host)
        let shown = FakeUI.node(.textField, id: "passcode", value: "4821-fixture", frame: frame, pid: Self.host)

        let first = try #require(SecureFieldRecord.next(previous: nil, tree: Self.plain, filled: [secure], bootMarker: nil, now: Date()))
        #expect(first.entries == [SecureFieldRecord.Entry(id: "passcode", frame: frame)])
        #expect(!String(decoding: first.encoded(), as: UTF8.self).contains("4821"))

        let second = try #require(SecureFieldRecord.next(previous: first, tree: Self.plain, filled: [shown], bootMarker: nil, now: Date()))
        #expect(second.entries == first.entries)
        #expect(RevealedSecrets(second).matches(shown))
    }

    @Test("a fill's nodes reach the ledger only as a list the cache's tree does not hold")
    func fillStaysOutOfTheLedgersTree() async {
        let backend = GapBackend(plain: Self.plain, hidden: [Self.row(3)])
        let device = DeviceID(rawValue: "d", platform: .ios)
        let ledger = DeviceActivityLedger()
        await DeviceActivityLedger.$current.withValue(ledger) {
            ledger.recordTreeRead(Self.plain, on: device, startedAt: Date())
            let filled = await backend.withGapsFilled(Self.plain, on: device)
            #expect(Self.ids(filled).contains("row-3"))
            #expect(ledger.activities.first?.tree == Self.plain)
            #expect(ledger.activities.first?.filled.contains { $0.id == "row-3" } == true)
            ledger.recordTreeRead(Self.plain, on: device, startedAt: Date())
            #expect(ledger.activities.first?.filled.isEmpty == true)
        }
    }

    // MARK: Android

    static func android(_ role: UIRole, id: String? = nil, label: String? = nil, frame: UIFrame, order: Int? = nil, children: [UINode] = []) -> UINode {
        FakeUI.node(role, id: id, label: label, frame: frame, platform: .android, drawingOrder: order, children: children)
    }

    static func androidTree(_ children: [UINode]) -> UITree {
        UITree(platform: .android, device: "d", roots: [android(.application, label: "Playground", frame: FakeUI.frame(0, 0, 390, 844), children: children)])
    }

    static let androidTab = android(.button, id: "tab", label: "Saved Tab", frame: FakeUI.frame(0, 795, 390, 49), order: 2)

    @Test("a row every view shows and a touch reaches is added; the plain tree's nodes stay")
    func androidAddsReachedRow() {
        let row = Self.android(.button, id: "row", label: "Saved Item 1", frame: FakeUI.frame(0, 200, 390, 56))
        let pane = Self.android(.group, frame: FakeUI.frame(0, 100, 390, 695), order: 1, children: [row])
        let filled = TreeGapFill.filling(Self.androidTree([Self.androidTab]), from: Self.androidTree([pane, Self.androidTab]))

        #expect(filled.filledFromGaps == 1)
        #expect(Self.ids(filled) == ["row", "tab"])
    }

    @Test("a screen with nothing hidden comes back exactly as the plain read gave it")
    func androidNothingHidden() {
        let plain = Self.androidTree([Self.androidTab])
        let layout = Self.android(.group, frame: FakeUI.frame(0, 0, 390, 795), order: 1)
        let filled = TreeGapFill.filling(plain, from: Self.androidTree([layout, Self.androidTab]))
        #expect(filled == plain)
    }

    @Test("an empty container with only an id is not hidden content, and a cut every-view read keeps the plain tree")
    func androidContainersAndCutReads() {
        let row = Self.android(.button, id: "row", label: "Saved Item 1", frame: FakeUI.frame(0, 200, 390, 56))
        let list = Self.android(.group, id: "list", frame: FakeUI.frame(0, 100, 390, 300), order: 1, children: [Self.android(.group, frame: FakeUI.frame(0, 100, 390, 300))])
        let plain = Self.androidTree([Self.androidTab])
        #expect(TreeGapFill.filling(plain, from: Self.androidTree([list, Self.androidTab])) == plain)

        var cut = Self.androidTree([row, Self.androidTab])
        cut.sourceTruncated = true
        #expect(TreeGapFill.filling(plain, from: cut) == plain)
    }

    @Test("a keyboard's own views are never filled, and its window does not hide what the app draws beneath it")
    func androidKeyboardRoot() {
        let row = Self.android(.textField, id: "field", label: "Find Items", frame: FakeUI.frame(0, 200, 390, 44))
        let key = Self.android(.button, label: "Show emoji", frame: FakeUI.frame(10, 500, 44, 44))
        let keyboard = Self.android(.keyboard, label: "Keyboard", frame: FakeUI.frame(0, 50, 390, 794), children: [key])
        var plain = Self.androidTree([Self.androidTab])
        plain.roots.append(Self.android(.keyboard, label: "Keyboard", frame: FakeUI.frame(0, 50, 390, 794)))
        var every = Self.androidTree([row, Self.androidTab])
        every.roots.append(keyboard)

        let filled = TreeGapFill.filling(plain, from: every)
        #expect(filled.filledFromGaps == 1)
        #expect(Self.ids(filled).contains("field"))
        #expect(!filled.roots.flatMap { $0.flattened() }.contains { $0.label == "Show emoji" })
    }

    @Test("what is drawn beneath a sheet's backdrop is not added, though every view lists it")
    func androidCoveredStaysOut() {
        let address = Self.android(.text, id: "address", label: "Address bc1q", frame: FakeUI.frame(0, 200, 390, 40))
        let receipt = Self.android(.group, frame: FakeUI.frame(0, 100, 390, 300), order: 1, children: [address])
        let backdrop = Self.android(.button, label: "Dismiss", frame: FakeUI.frame(0, 0, 390, 844), order: 2)
        let plain = Self.androidTree([backdrop])
        let filled = TreeGapFill.filling(plain, from: Self.androidTree([receipt, backdrop]))
        #expect(filled.filledFromGaps == nil)
        #expect(!Self.ids(filled).contains("address"))
    }

    @Test("a row's middle under the tab bar is not added, and the listed element's own text repeats nothing")
    func androidOwnTextAndTabBar() {
        let under = Self.android(.button, id: "under", label: "Under Tab", frame: FakeUI.frame(0, 770, 390, 60))
        let pane = Self.android(.group, frame: FakeUI.frame(0, 100, 390, 744), order: 1, children: [under])
        let text = Self.android(.text, label: "Saved Tab", frame: FakeUI.frame(10, 805, 100, 20))
        var tab = Self.androidTab
        tab.children = [text]
        let filled = TreeGapFill.filling(Self.androidTree([Self.androidTab]), from: Self.androidTree([pane, tab]))
        #expect(filled.filledFromGaps == nil)
    }

    @Test("with a hidden page over listed rows, the rows count as beneath it, so the shared judgement drops them")
    func androidHiddenPageKeepsOrder() {
        let listed = (1...3).map { Self.android(.button, id: "under-\($0)", label: "Under \($0)", frame: FakeUI.frame(0, 100 + Double($0) * 56, 390, 56)) }
        let list = Self.android(.group, frame: FakeUI.frame(0, 100, 390, 695), order: 1, children: listed)
        let action = Self.android(.button, id: "page-action", label: "Page Action", frame: FakeUI.frame(0, 200, 390, 44), order: 1)
        let title = Self.android(.text, id: "page-title", label: "Hidden Page", frame: FakeUI.frame(0, 120, 390, 44), order: 2)
        let page = Self.android(.group, frame: FakeUI.frame(0, 100, 390, 695), order: 2, children: [action, title])
        let plain = Self.androidTree([list, Self.androidTab])
        let filled = TreeGapFill.filling(plain, from: Self.androidTree([list, page, Self.androidTab]))

        #expect(filled.filledFromGaps == 2)
        let chain = UITree.hitChain(in: filled.roots, at: UIPoint(x: 195, y: 220))
        #expect(chain.last?.id == "page-action")
    }

    // MARK: Selectors

    @Test("a selector with a match on screen pays for no fill; one with none reads and reaches the hidden row")
    func selectorsFillOnlyOnAMiss() async throws {
        let backend = GapBackend(plain: Self.plain, hidden: [Self.row(3)])
        let device = DeviceID(rawValue: "d", platform: .ios)
        let logger = OffsiderLogger()

        let listed = try await AccessibilityPoller.resolveWithPolling(query: .id("back"), on: backend, device: device, waitTimeout: 0, pollInterval: 0.01, logger: logger)
        #expect(listed.value.matched?.id == "back")
        #expect(backend.fills == 0)

        let hidden = try await AccessibilityPoller.resolveWithPolling(query: .label("Saved Item 3"), on: backend, device: device, waitTimeout: 0, pollInterval: 0.01, logger: logger)
        #expect(hidden.value.matched?.id == "row-3")
        #expect(backend.fills == 1)
    }

    // MARK: Android reads

    @Test("the Android fill reads every view once, and the tree cache only ever sees the plain read")
    func androidFillStaysOutOfTheCache() async throws {
        let rig = try HelperRig()
        let ledger = DeviceActivityLedger()
        try await DeviceActivityLedger.$current.withValue(ledger) {
            let plain = try await rig.read()
            let recorded = ledger.activities.first?.tree
            _ = await rig.backend.fillingGaps(in: plain, on: HelperRig.device, samples: nil)
            #expect(ledger.activities.first?.tree == recorded)
        }
        let dumps = rig.device.frames.filter { $0.op == "dump" }.map(\.json)
        #expect(dumps.count == 2)
        #expect(dumps.last?.contains(#""notImportant":true"#) == true)
    }

    // MARK: The centre read

    @MainActor
    private final class ZoomProber: FakeDeviceBackend, PresentationProbing {
        var zoomKnown = false
        var answers: [UINode?] = []
        private(set) var probes = 0

        func probe(at point: UIPoint, on id: DeviceID) async throws -> UINode? {
            probes += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }

        func knowsDisplayZoom(on id: DeviceID) -> Bool { zoomKnown }
    }

    @Test("a centre read started before the tree read found a display zoom is read again; a known zoom or none keeps the first answer")
    func centreReadAfterZoom() async throws {
        let device = DeviceID(rawValue: "d", platform: .ios)
        let first = Self.node(.button, id: "off-centre", label: "Off Centre", y: 500)
        let second = Self.node(.button, id: "true-centre", label: "True Centre", y: 400)
        let backend = ZoomProber(platform: .ios, trees: [Self.plain], screenshots: [], screen: UIScreenInfo(width: 390, height: 844))
        backend.answers = [first, second]

        let pending = try #require(await PresentationCheck.start(backend: backend, device: device))
        backend.zoomKnown = true
        #expect(await pending.centre()?.hit.id == "true-centre")
        #expect(backend.probes == 2)

        backend.answers = [first, second]
        let known = try #require(await PresentationCheck.start(backend: backend, device: device))
        #expect(await known.centre()?.hit.id == "off-centre")

        backend.zoomKnown = false
        backend.answers = [first, second]
        let none = try #require(await PresentationCheck.start(backend: backend, device: device))
        #expect(await none.centre()?.hit.id == "off-centre")
    }
}
