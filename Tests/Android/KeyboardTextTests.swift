import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

/// Keyboard text beside the keys, from dumps recorded with Gboard on Offsider_E2E_Fold and Samsung Keyboard on a phone, labels synthetic.
@Suite("Keyboard text")
@MainActor
struct KeyboardTextTests {
    static let clip = "synthetic-clip-0001"
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/keyboards")

    static func dump(_ name: String) throws -> HelperDump {
        try JSONDecoder().decode(HelperDump.self, from: Data(contentsOf: fixtures.appendingPathComponent(name)))
    }

    static func tree(_ name: String) throws -> UITree {
        let dump = try dump(name)
        let scale = Double(dump.display.densityDpi) / 160
        var tree = UITree(platform: .android, device: "emulator-5556", roots: HelperTreeMapping.roots(from: dump, scale: scale, pid: 1).roots)
        tree.windows = HelperTreeMapping.windows(from: dump, scale: scale)
        return tree
    }

    static func keyboard(_ tree: UITree) throws -> [UINode] {
        try #require(tree.roots.first { $0.role == .keyboard }).flattened()
    }

    /// Every string a node carries, as output, selectors and the cache could read it.
    static func texts(_ nodes: [UINode]) -> [String] {
        nodes.flatMap { node -> [String?] in
            guard case .android(let attributes) = node.native else { return [node.label, node.value] }
            return [node.label, node.value, attributes.text, attributes.contentDescription, attributes.hint, attributes.stateDescription]
        }.compactMap { $0 }
    }

    // MARK: - Trees

    @Test("Gboard: keys keep their labels; the clipboard chip and the word suggestions it draws as keys are drawn show none")
    func gboardChip() throws {
        let tree = try Self.tree("gboard-clipboard-chip.json")
        let keyboard = try Self.keyboard(tree)
        let texts = Self.texts(tree.roots.flatMap { $0.flattened() })

        #expect(!texts.contains { $0.contains(Self.clip) || $0.contains("synthetic-word") || $0.contains("🌟") })
        #expect(keyboard.compactMap(\.label) == [
            "Gboard", "Open features menu", KeyboardText.marker, KeyboardText.marker, KeyboardText.marker, KeyboardText.marker,
            "Use voice typing", "q", "w", "Shift", "Delete", "Symbol keyboard", "Space", "Done", "Back",
        ])
        #expect(KeyboardText.hiddenCount(in: tree.roots) == 3)
    }

    @Test("Gboard's floating chip, in nothing that scrolls, is hidden too")
    func gboardFloatingChip() throws {
        let chip = #"{"i":1,"class":"android.widget.FrameLayout","package":"com.google.android.inputmethod.latin","bounds":[180,808,606,856],"clickable":true,"children":[{"i":2,"class":"android.widget.TextView","package":"com.google.android.inputmethod.latin","resourceId":"com.google.android.inputmethod.latin:id/0_resource_name_obfuscated","text":"synthetic-clip-0001","bounds":[180,808,606,856]}]}"#
        let keyboard = #"{"id":2337,"type":"inputMethod","layer":1,"title":"Gboard","bounds":[0,800,1080,2424],"active":false,"focused":false,"root":{"i":0,"class":"android.widget.FrameLayout","package":"com.google.android.inputmethod.latin","bounds":[0,800,1080,2424],"children":[\#(chip)]}}"#
        let roots = HelperTreeMapping.roots(from: try HelperTreeMappingTests.dump(HelperTreeMappingTests.appWindow("", firstIndex: 3) + "," + keyboard), scale: 2.625, pid: 1).roots

        #expect(!Self.texts(roots.flatMap { $0.flattened() }).contains { $0.contains(Self.clip) })
        #expect(KeyboardText.hiddenCount(in: roots) == 1)
    }

    @Test("Samsung Keyboard read with every view: letters drawn in text views stay, the clipboard suggestion goes")
    func samsungEveryView() throws {
        let tree = try Self.tree("samsung-keyboard-every-view.json")
        let keyboard = try Self.keyboard(tree)
        let labels = keyboard.compactMap(\.label)

        #expect(!Self.texts(tree.roots.flatMap { $0.flattened() }).contains { $0.contains(Self.clip) })
        #expect(labels.contains("Close"))
        #expect(["1", "q", "w", "Shift off", "Backspace"].allSatisfy(labels.contains))
        // A key whose drawn text is not its own name hides with it: the space bar's language and Enter's action word.
        #expect(!labels.contains("Space bar") && !labels.contains("English (UK)") && !labels.contains("Done"))
        #expect(KeyboardText.hiddenCount(in: tree.roots) == 3)
    }

    @Test("a Gboard key id never lets a key's own text through")
    func keyIDWithText() throws {
        let node = UINode(
            role: .button, id: "com.google.android.inputmethod.latin:id/key_pos_header_clip", label: Self.clip,
            native: .android(AndroidNativeAttributes(className: "android.widget.FrameLayout", resourceId: "com.google.android.inputmethod.latin:id/key_pos_header_clip", text: Self.clip))
        )
        let root = KeyboardText.hiding(UINode(role: .keyboard, label: "Gboard", native: .android(AndroidNativeAttributes()), children: [node]))

        #expect(root.children[0].label == KeyboardText.marker)
        #expect(root.label == "Gboard")
    }

    @Test("a selector never matches hidden keyboard text, but still finds a key")
    func selectors() throws {
        let roots = try Self.tree("gboard-clipboard-chip.json").roots

        #expect(AccessibilityTargetResolver.candidates(roots: roots, query: .labelContains("synthetic-clip"), elementType: nil).matches.isEmpty)
        #expect(AccessibilityTargetResolver.candidates(roots: roots, query: .label("Delete"), elementType: nil).matches.count == 1)
    }

    @Test("describe-ui counts the hidden suggestion once, in the footer and the JSON")
    func outputCounts() throws {
        let shown = try Self.tree("gboard-clipboard-chip.json").redacted()
        let text = String(decoding: UITreeRenderer.render(shown, UITreeRenderOptions(format: .text)), as: UTF8.self)
        let json = String(decoding: UITreeRenderer.render(shown, UITreeRenderOptions(format: .json, compact: true)), as: UTF8.self)

        #expect(text.hasSuffix("# redacted: 3 keyboard elements\n"))
        #expect(json.contains(#""redacted":0,"revealed":0,"keyboardElements":3"#))
        #expect(!text.contains(Self.clip) && !json.contains(Self.clip))
    }

    @Test("the tree cache on disk never holds keyboard text")
    func cache() throws {
        let tree = try Self.tree("gboard-clipboard-chip.json")
        let record = TreeCacheRecord(platform: .android, device: "emulator-5556", command: "describe-ui", writtenAt: Date(), roots: tree.redacted(scope: .cache).roots)
        let written = String(decoding: record.encoded(), as: UTF8.self)

        #expect(!written.contains(Self.clip))
        #expect(written.contains("Delete"))
    }

    // MARK: - Copy preview

    static let previewWindow = #"{"id":977,"type":"system","layer":4,"bounds":[0,1710,274,1943],"active":true,"focused":false,"root":{"i":0,"class":"android.widget.FrameLayout","package":"com.android.systemui","resourceId":"com.android.systemui:id/clipboard_ui","bounds":[0,1710,274,1943],"children":[{"i":1,"class":"android.widget.TextView","package":"com.android.systemui","resourceId":"com.android.systemui:id/text_preview","text":"synthetic-clip-0001","bounds":[20,1730,254,1923]}]}}"#

    @Test("the copy preview in front shows no text, and describe-ui counts it")
    func previewInFront() throws {
        let roots = HelperTreeMapping.roots(from: try HelperTreeMappingTests.dump(Self.previewWindow + "," + HelperTreeMappingTests.appWindow("", active: false)), scale: 2.625, pid: 1).roots
        let shown = UITree(platform: .android, device: "emulator-5556", roots: roots).redacted()

        #expect(roots.first.map(CopyPreview.isPreview) == true)
        #expect(!Self.texts(roots.flatMap { $0.flattened() }).contains { $0.contains(Self.clip) })
        #expect(shown.redaction?.footer == "# redacted: 1 copy preview")
    }

    @Test("only an untitled system window that is no bar may be the copy preview")
    func previewCandidates() {
        func window(_ id: Int, _ frame: UIFrame, kind: String = "system", title: String? = nil) -> UIWindowInfo {
            UIWindowInfo(id: id, kind: kind, layer: id, title: title, active: false, focused: false, package: nil, bounds: frame)
        }
        let windows = [
            window(1, UIFrame(x: 0, y: 0, width: 411, height: 914), kind: "application"),
            window(2, UIFrame(x: 0, y: 0, width: 411, height: 24)),
            window(3, UIFrame(x: 0, y: 866, width: 411, height: 48)),
            window(4, UIFrame(x: 0, y: 0, width: 48, height: 914)),
            window(5, UIFrame(x: 363, y: 0, width: 48, height: 914)),
            window(6, UIFrame(x: 0, y: 840, width: 411, height: 74), title: "Taskbar"),
            window(7, UIFrame(x: 0, y: 701, width: 112, height: 96)),
        ]

        #expect(CopyPreview.candidates(in: windows).map(\.id) == [7])
    }

    // MARK: - Screenshots and video

    static let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)

    static func capture() throws -> CapturedScreen {
        try ScreenCapture.make(png: try ScreenshotMaskTests.whitePNG(), platform: .android, screen: screen)
    }

    /// The playground with Gboard's chip and a key, and the copy preview's window, in points of the 390 x 844 screen.
    static func screenTree() -> UITree {
        func android(_ text: String? = nil, _ description: String? = nil) -> UINative {
            .android(AndroidNativeAttributes(className: "android.widget.TextView", text: text, contentDescription: description))
        }
        let chip = UINode(role: .text, label: clip, frame: UIFrame(x: 100, y: 600, width: 150, height: 20), native: android(clip))
        let key = UINode(role: .button, label: "q", frame: UIFrame(x: 10, y: 700, width: 30, height: 40), native: android(nil, "q"))
        let keyboard = KeyboardText.hiding(UINode(role: .keyboard, label: "Gboard", frame: UIFrame(x: 0, y: 590, width: 390, height: 254), native: android(), children: [chip, key]))
        let app = UINode(role: .application, label: "OffsiderPlaygroundRN", frame: UIFrame(x: 0, y: 0, width: 390, height: 844), native: android())
        var tree = UITree(platform: .android, device: "emulator-5556", screen: screen, roots: [app, keyboard])
        tree.windows = [
            UIWindowInfo(id: 1, kind: "application", layer: 1, title: "OffsiderPlaygroundRN", active: true, focused: true, package: nil, bounds: app.frame),
            UIWindowInfo(id: 2, kind: "inputMethod", layer: 2, title: "Gboard", active: false, focused: false, package: nil, bounds: keyboard.frame),
            UIWindowInfo(id: 3, kind: "system", layer: 3, title: nil, active: false, focused: false, package: nil, bounds: UIFrame(x: 0, y: 480, width: 100, height: 90), copyPreview: true),
        ]
        return tree
    }

    @Test("screenshots paint keyboard text and the copy preview with password fields, and leave the keys")
    func screenshotPaints() throws {
        let result = try ScreenCapture.masking(try Self.capture(), plan: MaskPlan(secure: true), tree: Self.screenTree())

        #expect(result.painted == [.secure: 0, .keyboard: 1, .copyPreview: 1])
        #expect(ScreenshotMaskTests.point(result.capture.image, 175, 610) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.point(result.capture.image, 50, 525) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.point(result.capture.image, 25, 720) == ScreenshotMaskTests.white)
    }

    @Test("with password masking off, a person's choice, neither is painted")
    func screenshotUnmasked() throws {
        let result = try ScreenCapture.masking(try Self.capture(), plan: MaskPlan(secure: false), tree: Self.screenTree())

        #expect(result.painted.isEmpty)
        #expect(ScreenshotMaskTests.point(result.capture.image, 175, 610) == ScreenshotMaskTests.white)
    }

    @Test("a keyboard window the tree could not read is painted whole")
    func unreadKeyboard() throws {
        var tree = Self.screenTree()
        tree.roots.removeLast()
        tree.windows?.removeLast()
        let result = try ScreenCapture.masking(try Self.capture(), plan: MaskPlan(secure: true), tree: tree)

        #expect(result.painted[.keyboard] == 1)
        #expect(ScreenshotMaskTests.point(result.capture.image, 25, 720) == ScreenshotMaskTests.black)
    }

    @Test("video will not start while keyboard text or the copy preview shows, but will over keys alone")
    func video() {
        var keysOnly = Self.screenTree()
        keysOnly.roots[1].children.removeFirst()
        keysOnly.windows?.removeLast()
        var previewOnly = keysOnly
        previewOnly.windows = Self.screenTree().windows

        #expect(VideoMaskPolicy.keyboardTextRefusal(command: "record-video", in: Self.screenTree())?.contains("Close the keyboard") == true)
        #expect(VideoMaskPolicy.keyboardTextRefusal(command: "record-video", in: previewOnly)?.contains("copy preview") == true)
        #expect(VideoMaskPolicy.keyboardTextRefusal(command: "record-video", in: keysOnly) == nil)
    }

    @Test("an every-window read tells the copy preview from another untitled system window")
    func previewInDump() throws {
        let dump = try HelperTreeMappingTests.dump(Self.previewWindow + "," + HelperTreeMappingTests.statusBar.replacingOccurrences(of: #""focused":false}"#, with: #""focused":false,"root":{"i":9,"class":"android.widget.FrameLayout","package":"com.android.systemui","resourceId":"com.android.systemui:id/status_bar","bounds":[0,0,1080,142]}}"#))

        #expect(dump.windows.compactMap(\.root).map(HelperTreeMapping.isCopyPreview) == [true, false])
    }

    @Test("a golden capture takes Gboard's toolbar, which trees now hide, and refuses a clipboard chip without naming it")
    func captureGuard() throws {
        let toolbar = try JSONSerialization.jsonObject(with: Data(contentsOf: TreeGoldens.root.appendingPathComponent("android/batch-login-flow/raw.json")))
        #expect(throws: Never.self) { try TreeGoldenCaptureTests.requireOnlyKeys(toolbar, screen: "batch-login-flow") }

        let chip = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("gboard-clipboard-chip.json")))
        let error = #expect(throws: DescribeUIError.self) { try TreeGoldenCaptureTests.requireOnlyKeys(["platform": "android", "source": chip], screen: "text-input") }
        let message = String(describing: error)
        #expect(message.contains("text-input: the keyboard holds"))
        #expect(!message.contains(Self.clip))
    }
}
