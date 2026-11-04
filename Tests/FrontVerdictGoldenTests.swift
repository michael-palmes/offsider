import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// The on-screen judgement's verdicts on every tree golden and on larger screens than the playground's, kept in `Tests/Goldens/front/`, so a faster judge is held to the same answers.
@Suite("Front verdict goldens")
@MainActor
struct FrontVerdictGoldenTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens/front")
    static let refresh = "After a reviewed change to the on-screen judgement, run OFFSIDER_GOLDENS_UPDATE=1 swift test --filter FrontVerdictGoldenTests."

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let tree: @Sendable () throws -> UITree
        var testDescription: String { name }
    }

    static let cases: [Case] = TreeGoldens.all().map { golden in
        Case(name: golden.name.replacingOccurrences(of: "/", with: "-")) { try TreeGoldens.tree(of: golden) }
    } + FrontFixtures.all.map { fixture in
        Case(name: fixture.name) { fixture.tree() }
    }

    @Test("every tree's verdicts match its committed file", arguments: cases)
    func verdictsMatch(test: Case) throws {
        let rendered = Self.render(try test.tree())
        let url = Self.root.appendingPathComponent("\(test.name).txt")
        if TreeGoldens.isUpdating {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let committed = try String(contentsOf: url, encoding: .utf8)
        #expect(rendered == committed, "\(test.name) changed. \(Self.refresh)")
    }

    @Test("every committed verdict file has a tree")
    func noStrayFiles() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.root.path).filter { $0.hasSuffix(".txt") }
        #expect(Set(names) == Set(Self.cases.map { "\($0.name).txt" }))
    }

    @Test("the larger screens reach each verdict the judge gives: a keyboard cover, a LogBox touch area, a page over a screen, a part past its scroll view, a bar and a system bar")
    func fixturesCoverEveryVerdict() throws {
        let rendered = FrontFixtures.all.map { Self.render($0.tree()) }.joined()
        for verdict in ["covered by keyboard", "logBoxTouchArea, sure", "beneath \"", "clipped below", "drawingOrder, sure", "treeOrder, guess", "hitTest, sure", "systemBar, sure"] {
            #expect(rendered.contains(verdict), "no fixture gives \(verdict)")
        }
    }

    /// The judgement `describe-ui --summary` makes with no point read, as on a physical iPhone and Android; on iOS also with each contested point read as its deepest node, as a simulator's hit-test might answer.
    static func render(_ tree: UITree) -> String {
        let listed = DescribeUI.listed(tree, filter: UITreeRenderOptions.summary.filter)
        let flat = tree.roots.flatMap { $0.flattened() }
        var text = "# \(flat.count) nodes, \(listed.count) listed\n"
        text += "## no point read\n" + lines(judge(tree, listed: listed, hitTest: false), flat: flat)
        if tree.platform == .ios {
            text += "## hit-tested\n" + lines(judge(tree, listed: listed, hitTest: true), flat: flat)
        }
        return text
    }

    static func judge(_ tree: UITree, listed: [Int], hitTest: Bool) -> FrontReading {
        var reading = FrontReading()
        let plan = FrontJudge.Plan(tree: tree, indexes: listed, reading: reading, spareReads: hitTest ? FrontJudge.hitLimit : nil)
        var hits: [Int: UINode] = [:]
        if hitTest {
            for entry in plan.contested.prefix(FrontJudge.hitLimit) {
                hits[entry.index] = tree.deepestNode(at: entry.judging.point)
            }
        }
        plan.record(into: &reading, hits: hits, hitTested: hitTest, platform: tree.platform)
        plan.settleGroups(in: &reading)
        return reading
    }

    static func lines(_ reading: FrontReading, flat: [UINode]) -> String {
        let indexes = Set(reading.beneath.keys).union(reading.clipped.keys).union(reading.covered.keys).union(reading.judged.keys).sorted()
        return indexes.map { index in
            var parts = ["\(index) \(describe(flat[index]))"]
            if let page = reading.beneath[index] { parts.append("beneath \"\(page)\"") }
            if let side = reading.clipped[index] { parts.append("clipped \(side)") }
            if let verdict = reading.covered[index] { parts.append("covered by \(describe(verdict))") }
            if let judged = reading.judged[index] {
                var judgement = "at \(number(judged.point.x)),\(number(judged.point.y)) "
                judgement += judged.verdict.map { "judged \(describe($0))" } ?? "reaches"
                if let own = judged.ownHit { judgement += own ? ", own hit" : ", other hit" }
                if judged.unsure { judgement += ", unsure" }
                parts.append(judgement)
            }
            return parts.joined(separator: ": ") + "\n"
        }.joined()
    }

    static func describe(_ node: UINode) -> String {
        var parts = [node.role.rawValue]
        if let name = node.normalizedID ?? node.normalizedLabel { parts.append("\"\(SelectorText.truncated(name, limit: 40))\"") }
        if let frame = node.frame { parts.append("\(number(frame.x)),\(number(frame.y)) \(number(frame.width))x\(number(frame.height))") }
        return parts.joined(separator: " ")
    }

    static func describe(_ verdict: CoverVerdict) -> String {
        var text = "\(describe(verdict.cover)) (\(verdict.evidence.rawValue), \(verdict.isConfident ? "sure" : "guess")"
        if let screen = verdict.screen { text += ", on \"\(screen)\"" }
        if verdict.hitFoundTarget { text += ", hit found target" }
        return text + ")"
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Screens larger and denser than the playground's, in the shapes a physical iPhone's runner and Android's helper list them.
enum FrontFixtures {
    struct Fixture: Sendable {
        let name: String
        let tree: @Sendable () -> UITree
    }

    static let all: [Fixture] = [
        Fixture(name: "ios-device-long-scroll", tree: iosLongScroll),
        Fixture(name: "ios-device-keyboard-form", tree: iosKeyboardForm),
        Fixture(name: "ios-device-pages", tree: iosPages),
        Fixture(name: "ios-device-logbox", tree: iosLogBox),
        Fixture(name: "android-keyboard-form", tree: androidKeyboardForm),
        Fixture(name: "android-logbox-inset", tree: androidLogBoxInset),
        Fixture(name: "android-long-list", tree: androidLongList),
    ]

    static let width = 430.0
    static let height = 932.0

    static func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> UIFrame {
        UIFrame(x: x, y: y, width: width, height: height)
    }

    // MARK: iOS, as the iPhone runner lists a native screen: one pid on the root, types on every node.

    static func ios(_ role: UIRole, _ type: String, id: String? = nil, label: String? = nil, value: String? = nil, _ frame: UIFrame, pid: Int? = nil, _ children: [UINode] = []) -> UINode {
        UINode(role: role, id: id, label: label, value: value, frame: frame, enabled: true, state: UIState(selected: false), native: .ios(IOSNativeAttributes(type: type, pid: pid)), children: children)
    }

    static func screen(_ content: [UINode]) -> UINode {
        let full = frame(0, 0, width, height)
        func wrap(_ depth: Int, _ inner: [UINode]) -> [UINode] {
            depth == 0 ? inner : [ios(.other, "Other", full, wrap(depth - 1, inner))]
        }
        return ios(.application, "Application", label: "OffsiderPlayground", full, pid: 1000, [ios(.window, "Window", full, wrap(5, content))])
    }

    static func navigationBar(_ title: String) -> UINode {
        ios(.header, "NavigationBar", id: title, frame(0, 59, width, 54), [
            ios(.button, "Button", id: "BackButton", label: "Offsider Playground", frame(20, 59, 44, 44)),
            ios(.text, "StaticText", label: title, frame(150, 71, 130, 21)),
        ])
    }

    static func cell(_ id: String, _ label: String, y: Double, height: Double = 64) -> UINode {
        ios(.cell, "Cell", id: id, label: label, frame(0, y, width, height), [
            ios(.other, "Other", frame(0, y, width, height), [ios(.other, "Other", frame(0, y, width, height))]),
            ios(.text, "StaticText", label: label, frame(20, y, 390, height)),
            ios(.other, "Other", frame(20, y + height - 1, 390, 1)),
        ])
    }

    /// A long list under a navigation bar, its scroll bar, and a toolbar over its last rows.
    @Sendable static func iosLongScroll() -> UITree {
        let rows = (0..<120).map { cell("long-scroll-test-row-\($0)", "Long Scroll Row \($0)", y: 165 + Double($0) * 64) }
        let list = ios(.list, "Table", id: "long-scroll-test-scroll-view", frame(0, 165, width, 684), rows + [
            ios(.other, "Other", label: "Vertical scroll bar, 12 pages", frame(397, 165, 30, 684)),
        ])
        let toolbar = ios(.other, "Toolbar", id: "long-scroll-test-toolbar", frame(0, 820, width, 112), [
            ios(.button, "Button", id: "long-scroll-test-top", label: "Top", frame(20, 830, 80, 44)),
            ios(.button, "Button", id: "long-scroll-test-bottom", label: "Bottom", frame(330, 830, 80, 44)),
        ])
        let state = ios(.text, "StaticText", id: "long-scroll-test-state", label: "Long Scroll Selected: Row 3", frame(16, 129, 212, 20))
        return UITree(platform: .ios, device: "<ios-device>", roots: [screen([navigationBar("Long Scroll"), state, list, toolbar])])
    }

    /// A form whose lower fields the keyboard covers, the keyboard listed as the app's last window.
    @Sendable static func iosKeyboardForm() -> UITree {
        let fields = (0..<12).flatMap { row -> [UINode] in
            let y = 130 + Double(row) * 60
            return [
                ios(.text, "StaticText", label: "Field \(row)", frame(20, y, 100, 20)),
                ios(.textField, "TextField", id: "form-field-\(row)", value: row == 0 ? "typed" : nil, frame(20, y + 22, 390, 34)),
            ]
        }
        let save = ios(.button, "Button", id: "form-save", label: "Save", frame(20, 860, 390, 44))
        let keys = "qwertyuiop".enumerated().map { offset, key in
            ios(.button, "Key", label: String(key), frame(3 + Double(offset) * 42.5, 600, 38, 46))
        } + [ios(.button, "Key", label: "return", frame(320, 750, 106, 46))]
        var tree = UITree(platform: .ios, device: "<ios-device>", roots: [screen([navigationBar("Form")] + fields + [save])])
        tree.roots[0].children.append(ios(.keyboard, "Keyboard", frame(0, 590, width, 342), keys))
        return tree
    }

    /// A pushed page over the screen it came from, both listing the same Back button, as a physical iPhone keeps both mounted.
    @Sendable static func iosPages() -> UITree {
        func page(_ id: String, _ title: String, rows: Int) -> UINode {
            ios(.other, "Other", id: id, frame(0, 0, width, height), [navigationBar(title)] + (0..<rows).map { row in
                ios(.button, "Button", id: "\(id)-row-\(row)", label: "\(title) Row \(row)", frame(16, 130 + Double(row) * 52, 398, 44))
            })
        }
        return UITree(platform: .ios, device: "<ios-device>", roots: [screen([page("stack-test-page-1", "Page 1", rows: 14), page("stack-test-page-2", "Page 2", rows: 10)])])
    }

    /// A LogBox toast over the last rows of a list, whose touch area reaches a point above its frame.
    @Sendable static func iosLogBox() -> UITree {
        let rows = (0..<16).map { cell("rows-test-row-\($0)", "Row \($0)", y: 120 + Double($0) * 50, height: 50) }
        let list = ios(.list, "Table", id: "rows-test-list", frame(0, 120, width, 812), rows)
        let toast = ios(.button, "Other", label: "!, Request failed", frame(10, 838, width - 20, 48))
        return UITree(platform: .ios, device: "<ios-device>", roots: [screen([navigationBar("Rows"), list, toast])])
    }

    // MARK: Android, as the helper lists a React Native screen: class names, drawing orders and window layers.

    static func android(
        _ role: UIRole, _ className: String, id: String? = nil, label: String? = nil, _ frame: UIFrame, order: Int? = nil, layer: Int? = nil,
        visible: Bool? = true, _ children: [UINode] = []
    ) -> UINode {
        let attributes = AndroidNativeAttributes(
            className: className, resourceId: id, package: "com.mpalmes.offsider.playground.rn", text: label, visibleToUser: visible, drawingOrder: order, windowLayer: layer
        )
        return UINode(role: role, id: id, label: label, frame: frame, enabled: true, native: .android(attributes), children: children)
    }

    static let androidWidth = 411.0
    static let androidHeight = 923.0

    static func androidApp(_ content: [UINode]) -> UINode {
        let full = frame(0, 0, androidWidth, androidHeight)
        return android(.application, "android.widget.FrameLayout", label: "Offsider Playground", full, layer: 0, [
            android(.other, "android.view.ViewGroup", full, order: 1, content),
        ])
    }

    static func androidWindows(keyboard: UIFrame? = nil, statusBar: Bool = false) -> [UIWindowInfo] {
        var windows = [UIWindowInfo(id: 1, kind: "application", layer: 0, title: "Offsider Playground", active: true, focused: true, package: "com.mpalmes.offsider.playground.rn", bounds: frame(0, 0, androidWidth, androidHeight))]
        if statusBar {
            windows.append(UIWindowInfo(id: 2, kind: "system", layer: 2, title: "StatusBar", active: false, focused: false, package: "com.android.systemui", bounds: frame(0, 0, androidWidth, 24)))
        }
        if let keyboard {
            windows.append(UIWindowInfo(id: 3, kind: "inputMethod", layer: 1, title: nil, active: false, focused: false, package: nil, bounds: keyboard))
        }
        return windows
    }

    /// A form under Gboard: the keyboard's root spans the screen while its window takes touches only around the keys, and the helper marks the field it hides wholly as not visible.
    @Sendable static func androidKeyboardForm() -> UITree {
        let fields = (0..<10).flatMap { row -> [UINode] in
            let y = 100 + Double(row) * 70
            return [
                android(.text, "android.widget.TextView", label: "Field \(row)", frame(16, y, 120, 20), order: row * 2 + 1),
                android(.textField, "android.widget.EditText", id: "form-field-\(row)", frame(16, y + 24, 379, 40), order: row * 2 + 2, visible: row != 8),
            ]
        }
        let keys = "qwertyuiop".enumerated().map { offset, key in
            android(.button, "android.widget.Button", label: String(key), frame(2 + Double(offset) * 40.9, 640, 38, 52), order: offset + 1)
        } + [android(.button, "android.widget.Button", label: "Done", frame(330, 840, 77, 52), order: 11)]
        let keyboard = android(.keyboard, "android.widget.FrameLayout", frame(0, 24, androidWidth, 899), layer: 1, keys)
        var tree = UITree(platform: .android, device: "<android-device>", roots: [androidApp(fields), keyboard])
        tree.windows = androidWindows(keyboard: frame(0, 620, androidWidth, 303))
        return tree
    }

    /// An edge-to-edge app drawn under the status bar, whose LogBox list takes touches higher by the bar's height, with one button partly and one text wholly under the bar.
    @Sendable static func androidLogBoxInset() -> UITree {
        let header = android(.header, "android.widget.TextView", label: "Rows", frame(16, 10, 200, 30), order: 1)
        let rows = (0..<16).map { row in
            android(.button, "android.view.ViewGroup", id: "rows-test-row-\(row)", label: "Row \(row)", frame(0, 60 + Double(row) * 54, androidWidth, 50), order: row + 2)
        }
        let toast = android(.button, "android.view.ViewGroup", label: "!, Request failed", frame(10, 850, androidWidth - 20, 56), order: 40)
        let partlyUnderBar = android(.button, "android.view.ViewGroup", id: "rows-test-status", label: "Status", frame(300, 0, 100, 44), order: 41)
        let underBar = android(.text, "android.widget.TextView", id: "rows-test-clock", label: "Clock", frame(230, 2, 60, 20), order: 42)
        var tree = UITree(platform: .android, device: "<android-device>", roots: [androidApp([header] + rows + [toast, partlyUnderBar, underBar])])
        tree.windows = androidWindows(statusBar: true)
        return tree
    }

    /// A long React Native list with a footer bar drawn over its last rows and a sheet drawn over its top.
    @Sendable static func androidLongList() -> UITree {
        let rows = (0..<200).map { row in
            android(.button, "android.view.ViewGroup", id: "rows-test-row-\(row)", label: "Row \(row)", frame(0, 120 + Double(row) * 48, androidWidth, 44), order: row + 1, [
                android(.text, "android.widget.TextView", label: "Row \(row) detail", frame(16, 130 + Double(row) * 48, 200, 20), order: 1),
            ])
        }
        let list = android(.scrollView, "android.widget.ScrollView", id: "rows-test-list", frame(0, 120, androidWidth, 803), order: 1, rows)
        let footer = android(.other, "android.view.ViewGroup", id: "rows-test-footer", frame(0, 840, androidWidth, 83), order: 2, [
            android(.button, "android.view.ViewGroup", id: "rows-test-save", label: "Save", frame(16, 850, 180, 48), order: 1),
            android(.button, "android.view.ViewGroup", id: "rows-test-cancel", label: "Cancel", frame(215, 850, 180, 48), order: 2),
        ])
        let banner = android(.text, "android.widget.TextView", id: "rows-test-banner", label: "Saved", frame(0, 150, androidWidth, 60), order: 3)
        let title = android(.header, "android.widget.TextView", label: "Rows", frame(16, 60, 200, 40), order: 4)
        var tree = UITree(platform: .android, device: "<android-device>", roots: [androidApp([list, footer, banner, title])])
        tree.windows = androidWindows()
        return tree
    }
}
