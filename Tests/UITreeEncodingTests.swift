import Foundation
import OffsiderCore
import Testing

@Suite("UI Tree Encoding Tests")
struct UITreeEncodingTests {
    private func render(_ tree: UITree) -> String {
        String(decoding: tree.jsonData(), as: UTF8.self)
    }

    private func object(_ tree: UITree) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: tree.jsonData()) as? [String: Any])
    }

    private func firstRoot(_ tree: UITree) throws -> [String: Any] {
        let roots = try #require(try object(tree)["roots"] as? [[String: Any]])
        return try #require(roots.first)
    }

    private let bareNode = UINode(role: .other, native: .ios(IOSNativeAttributes()))

    @Test("the envelope starts with version, platform, device, screen and roots in that order")
    func envelopeKeyOrder() {
        let tree = UITree(platform: .ios, device: "DEVICE-1", roots: [])

        #expect(render(tree) == """
        {
          "version": 1,
          "platform": "ios",
          "device": "DEVICE-1",
          "screen": null,
          "roots": []
        }

        """)
    }

    @Test("a node writes every neutral key in schema order, children last")
    func nodeKeyOrder() throws {
        let text = render(UITree(platform: .ios, device: "D", roots: [bareNode]))
        let keys = ["\"role\"", "\"id\"", "\"label\"", "\"value\"", "\"frame\"", "\"enabled\"", "\"state\"", "\"native\"", "\"children\""]
        let offsets = try keys.map { key in try #require(text.range(of: key)?.lowerBound) }

        #expect(offsets == offsets.sorted())
    }

    @Test("absent values are written as explicit nulls, never omitted")
    func explicitNulls() throws {
        let root = try firstRoot(UITree(platform: .ios, device: "D", roots: [bareNode]))
        let state = try #require(root["state"] as? [String: Any])
        let native = try #require(root["native"] as? [String: Any])

        for key in ["id", "label", "value", "frame", "enabled"] {
            #expect(root[key] is NSNull, "\(key) should be null")
        }
        for key in ["checked", "selected", "focused"] {
            #expect(state[key] is NSNull, "state.\(key) should be null")
        }
        for key in ["type", "role", "subrole", "roleDescription", "title", "help", "contentRequired", "pid", "axFrame"] {
            #expect(native[key] is NSNull, "native.\(key) should be null")
        }
        #expect((native["customActions"] as? [Any])?.isEmpty == true)
        #expect((root["children"] as? [Any])?.isEmpty == true)
    }

    @Test("strings round-trip with quotes, escapes, slashes and emoji intact")
    func stringEscaping() throws {
        let label = "Say \"hi\"\\ now\n\tpath/to 🎉 \u{01}"
        let node = UINode(role: .text, label: label, native: .ios(IOSNativeAttributes()))
        let tree = UITree(platform: .ios, device: "D", roots: [node])

        #expect(try firstRoot(tree)["label"] as? String == label)
        #expect(render(tree).contains("path/to"))
    }

    @Test("whole-number frames print without a fraction and fractions keep their precision")
    func numberFormatting() throws {
        let frame = UIFrame(x: 16, y: 62.5, width: 1.0 / 3.0, height: 44)
        let node = UINode(role: .button, frame: frame, native: .ios(IOSNativeAttributes()))
        let tree = UITree(platform: .ios, device: "D", roots: [node])
        let decoded = try #require(try firstRoot(tree)["frame"] as? [String: Double])

        #expect(render(tree).contains("\"x\": 16,"))
        #expect(decoded == ["x": 16, "y": 62.5, "width": 1.0 / 3.0, "height": 44])
    }

    private func screenJSON(_ screen: UIScreenInfo, platform: DevicePlatform = .ios) -> String {
        let text = String(decoding: UITreeRenderer.render(
            UITree(platform: platform, device: "D", screen: screen, roots: []),
            UITreeRenderOptions(compact: true)
        ), as: UTF8.self)
        let start = text.range(of: #""screen":"#)!.upperBound
        let end = text.range(of: #","roots""#)!.lowerBound
        return String(text[start..<end])
    }

    @Test("a phone's screen is its shape, rotation and main display, with no posture")
    func phoneScreen() {
        let screen = UIScreenInfo(width: 874, height: 402, scale: 3, rotation: .landscapeFlipped)
        #expect(screenJSON(screen) == #"{"width":874,"height":402,"scale":3,"orientation":"landscape","rotation":90,"display":{"id":"main","platformId":"1"},"posture":null}"#)
    }

    @Test("a folded foldable's screen names the cover display and the closed posture")
    func foldedScreen() {
        let screen = UIScreenInfo(
            width: 466, height: 678, scale: 3, rotation: .portrait, rotationDegrees: 0,
            display: ScreenDisplay(id: "cover", platformId: "1"), posture: .closed
        )
        #expect(screenJSON(screen) == #"{"width":466,"height":678,"scale":3,"orientation":"portrait","rotation":0,"display":{"id":"cover","platformId":"1"},"posture":"closed"}"#)
    }

    @Test("Android's main display is display 0, and the backend's degrees win over the coordinate orientation's")
    func androidScreen() {
        let screen = UIScreenInfo(width: 411.43, height: 923.43, scale: 2.625, rotation: .portrait, rotationDegrees: 270)
        #expect(screenJSON(screen, platform: .android) == #"{"width":411.43,"height":923.43,"scale":2.625,"orientation":"portrait","rotation":270,"display":{"id":"main","platformId":"0"},"posture":null}"#)
    }

    @Test("an unread orientation has a shape but no rotation")
    func unreadRotation() {
        #expect(screenJSON(UIScreenInfo(width: 402, height: 874)) == #"{"width":402,"height":874,"scale":null,"orientation":"portrait","rotation":null,"display":{"id":"main","platformId":"1"},"posture":null}"#)
    }

    @Test("a square screen is portrait, and only a wider one is landscape", arguments: [
        ((500.0, 500.0), ScreenShape.portrait), ((500, 501), .portrait), ((501, 500), .landscape),
    ] as [((Double, Double), ScreenShape)])
    func shapeTie(size: (Double, Double), shape: ScreenShape) {
        #expect(UIScreenInfo(width: size.0, height: size.1).shape == shape)
    }

    @Test("the text header gives the shape and degrees, and a foldable's display and posture")
    func textHeader() {
        let folded = UIScreenInfo(
            width: 951, height: 669, scale: 3, rotation: .portrait, rotationDegrees: 90,
            display: ScreenDisplay(id: "inner", platformId: "3"), posture: .open
        )
        let header = { (screen: UIScreenInfo) in
            String(decoding: UITreeRenderer.render(UITree(platform: .ios, device: "D", screen: screen, roots: []), .summary), as: UTF8.self)
        }
        #expect(header(UIScreenInfo(width: 402, height: 874, scale: 3, rotation: .portrait)) == "# ios D 402x874 @3x portrait 0°\n")
        #expect(header(folded) == "# ios D 951x669 @3x landscape 90° inner open\n")
    }

    @Test("iOS native attributes are written flat under native")
    func iosNative() throws {
        let native = IOSNativeAttributes(
            type: "Button", role: "AXButton", roleDescription: "back button",
            customActions: ["Delete"], contentRequired: false, pid: 42, axFrame: "{{16, 62}, {44, 44}}"
        )
        let root = try firstRoot(UITree(platform: .ios, device: "D", roots: [UINode(role: .button, native: .ios(native))]))
        let decoded = try #require(root["native"] as? [String: Any])

        #expect(decoded["type"] as? String == "Button")
        #expect(decoded["role"] as? String == "AXButton")
        #expect(decoded["roleDescription"] as? String == "back button")
        #expect(decoded["customActions"] as? [String] == ["Delete"])
        #expect(decoded["contentRequired"] as? Bool == false)
        #expect(decoded["pid"] as? Int == 42)
        #expect(decoded["axFrame"] as? String == "{{16, 62}, {44, 44}}")
    }

    @Test("Android native attributes are written flat, and the type name drops the package")
    func androidNative() throws {
        let native = AndroidNativeAttributes(
            className: "android.widget.Switch", resourceId: "com.example:id/alerts",
            pixelFrame: UIFrame(x: 0, y: 0, width: 1080, height: 150), testTag: "alerts"
        )
        let node = UINode(role: .switch, state: UIState(checked: true), native: .android(native))
        let root = try firstRoot(UITree(platform: .android, device: "emulator-5554", roots: [node]))
        let decoded = try #require(root["native"] as? [String: Any])

        #expect(UINative.android(native).typeName == "Switch")
        #expect(decoded["className"] as? String == "android.widget.Switch")
        #expect((decoded["pixelFrame"] as? [String: Double])?["width"] == 1080)
        #expect(decoded["hint"] is NSNull)
        #expect((root["state"] as? [String: Any])?["checked"] as? Bool == true)
    }

    @Test("nested children keep their order")
    func childOrder() throws {
        let children = ["First", "Second", "Third"].map { UINode(role: .text, label: $0, native: .ios(IOSNativeAttributes())) }
        let parent = UINode(role: .group, native: .ios(IOSNativeAttributes()), children: children)
        let decoded = try #require(try firstRoot(UITree(platform: .ios, device: "D", roots: [parent]))["children"] as? [[String: Any]])

        #expect(decoded.map { $0["label"] as? String } == ["First", "Second", "Third"])
    }
}
