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

    @Test("screen info writes width, height, scale and orientation")
    func screenInfo() throws {
        let screen = UIScreenInfo(width: 402, height: 874, scale: 3, orientation: .portrait)
        let decoded = try #require(try object(UITree(platform: .ios, device: "D", screen: screen, roots: []))["screen"] as? [String: Any])

        #expect(decoded["width"] as? Double == 402)
        #expect(decoded["height"] as? Double == 874)
        #expect(decoded["scale"] as? Double == 3)
        #expect(decoded["orientation"] as? String == "portrait")
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
