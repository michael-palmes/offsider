import Foundation
@testable import Offsider
import OffsiderCore
import Testing

@Suite("UI Tree Renderer Tests")
struct UITreeRendererTests {
    private static let iosTree = UITree(
        platform: .ios,
        device: "IOS-UDID",
        screen: UIScreenInfo(width: 402, height: 874, scale: 3, rotation: .portrait),
        roots: [
            UINode(
                role: .application, label: "Playground", frame: UIFrame(x: 0, y: 0, width: 402, height: 874),
                native: .ios(IOSNativeAttributes(type: "Application", role: "AXApplication", pid: 42)),
                children: [
                    UINode(
                        role: .scrollView, frame: UIFrame(x: 0, y: 0, width: 402, height: 2000),
                        native: .ios(IOSNativeAttributes(type: "ScrollView")),
                        children: [
                            UINode(
                                role: .button, id: "size-s", label: "S", value: "Small",
                                frame: UIFrame(x: 16, y: 769, width: 85, height: 36), enabled: true,
                                native: .ios(IOSNativeAttributes(type: "Button", customActions: ["Size Guide"], axFrame: "{{16, 769}, {85, 36}}"))
                            ),
                            UINode(
                                role: .text, label: "Far below",
                                frame: UIFrame(x: 16, y: 1500, width: 200, height: 20),
                                native: .ios(IOSNativeAttributes(type: "StaticText"))
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )

    private static let androidTree = UITree(
        platform: .android,
        device: "emulator-5554",
        screen: UIScreenInfo(width: 411.4, height: 914.3, scale: 2.625, rotation: .landscape),
        roots: [
            UINode(
                role: .application, frame: UIFrame(x: 0, y: 0, width: 411.4, height: 914.3),
                native: .android(AndroidNativeAttributes(className: "android.widget.FrameLayout", package: "com.example")),
                children: [
                    UINode(
                        role: .switch, id: "alerts", label: "Alerts", enabled: false,
                        state: UIState(checked: true, selected: false, focused: nil),
                        native: .android(AndroidNativeAttributes(
                            className: "android.widget.Switch", resourceId: "com.example:id/alerts",
                            pixelFrame: UIFrame(x: 0, y: 0, width: 1080, height: 150), testTag: "alerts"
                        ))
                    ),
                ]
            ),
        ]
    )

    private func string(_ tree: UITree, _ options: UITreeRenderOptions) -> String {
        String(decoding: UITreeRenderer.render(tree, options), as: UTF8.self)
    }

    private func json(_ text: some StringProtocol) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func cliOptions(_ arguments: [String]) throws -> UITreeRenderOptions {
        try DescribeUIOutputOptions.parse(arguments).renderOptions()
    }

    @Test("default options render exactly the existing JSON", arguments: [iosTree, androidTree])
    func defaultIsByteIdentical(tree: UITree) {
        #expect(UITreeRenderer.render(tree, UITreeRenderOptions()) == tree.jsonData())
    }

    @Test("no CLI output flags gives the default options")
    func noFlagsIsDefault() throws {
        #expect(try cliOptions([]) == UITreeRenderOptions())
    }

    @Test("flat JSON lists nodes with index, parent and depth first and no children")
    func flatJSON() throws {
        var options = UITreeRenderOptions(flat: true)
        options.filter.onScreen = true
        let decoded = try json(string(Self.iosTree, options))
        let nodes = try #require(decoded["nodes"] as? [[String: Any]])
        let text = string(Self.iosTree, options)

        #expect(decoded["roots"] == nil)
        #expect(decoded["version"] as? Int == 2)
        #expect(nodes.map { $0["role"] as? String } == ["application", "scrollView", "button"])
        #expect(nodes[0]["parent"] is NSNull)
        #expect(nodes[2]["parent"] as? Int == 1)
        #expect(nodes[2]["depth"] as? Int == 2)
        #expect(nodes.allSatisfy { $0["children"] == nil })
        #expect(text.range(of: "\"index\"")!.lowerBound < text.range(of: "\"parent\"")!.lowerBound)
        #expect(text.range(of: "\"depth\"")!.lowerBound < text.range(of: "\"role\"")!.lowerBound)
    }

    @Test("ndjson starts with a screen line, then one object per node", arguments: [false, true])
    func ndjson(flat: Bool) throws {
        let output = string(Self.iosTree, UITreeRenderOptions(format: .ndjson, flat: flat))
        let lines = output.split(separator: "\n")
        let header = try json(lines[0])

        #expect(output.hasSuffix("\n"))
        #expect(header["roots"] == nil && header["nodes"] == nil)
        #expect((header["screen"] as? [String: Any])?["width"] as? Double == 402)
        #expect(lines.count == 1 + 4)
        for line in lines.dropFirst() {
            #expect(try json(line)["index"] is Int)
        }
    }

    @Test("text prints a header and one indented line per node")
    func textFormat() {
        let output = string(Self.iosTree, UITreeRenderOptions(format: .text))

        #expect(output == """
        # ios IOS-UDID 402x874 @3x portrait 0°
        application "Playground" (0,0 402x874)
          scrollView (0,0 402x2000)
            button "S" id=size-s value="Small" (16,769 85x36)
            text "Far below" (16,1500 200x20)

        """)
    }

    @Test("the summary names an open keyboard and LogBox logs after the device line, and JSON always carries the context")
    func contextHeaders() throws {
        let screen = UIFrame(x: 0, y: 0, width: 402, height: 874)
        let tree = UITree(platform: .ios, device: "IOS-UDID", screen: UIScreenInfo(width: 402, height: 874, scale: 3, rotation: .portrait), roots: [
            UINode(role: .application, label: "Playground", frame: screen, native: .ios(IOSNativeAttributes()), children: [
                UINode(role: .other, label: "2, Request failed", frame: UIFrame(x: 10, y: 806, width: 382, height: 48), native: .ios(IOSNativeAttributes())),
            ]),
            UINode(role: .keyboard, frame: UIFrame(x: 0, y: 574, width: 402, height: 300), native: .ios(IOSNativeAttributes())),
        ])

        let summary = string(tree, .summary)
        #expect(summary.hasPrefix("# ios IOS-UDID 402x874 @3x portrait 0°\n# keyboard shown\n# logbox: 2 logs\napplication"))

        let context = try #require(try json(string(tree, UITreeRenderOptions(compact: true)))["context"] as? [String: Any])
        #expect(context["window"] is NSNull)
        #expect(context["keyboard"] as? Bool == true)
        #expect((context["logbox"] as? [String: Any])?["logs"] as? Int == 2)

        #expect(!string(Self.iosTree, .summary).contains("\n# "))
    }

    @Test("text escapes strings, rounds fractions, and shows disabled, state and missing frames")
    func textDetails() {
        let output = string(Self.androidTree, UITreeRenderOptions(format: .text))
        let quirky = UITree(platform: .ios, device: "D", roots: [
            UINode(role: .text, id: "has space", label: "Say \"hi\"\n", frame: UIFrame(x: 1.0 / 3.0, y: 62.96, width: 10.25, height: 4),
                   state: UIState(selected: true, focused: true), native: .ios(IOSNativeAttributes())),
        ])

        #expect(output == """
        # android emulator-5554 411.4x914.3 @2.625x portrait 270°
        application (0,0 411.4x914.3)
          switch "Alerts" id=alerts (no frame) disabled checked

        """)
        #expect(string(quirky, UITreeRenderOptions(format: .text)).hasSuffix("""
        text "Say \\"hi\\"\\n" id="has space" (0.3,63 10.3x4) selected focused

        """))
    }

    @Test("flat text indents by kept ancestors, so filtered parents do not leave gaps, and the text below the screen becomes a run line")
    func flatTextIndent() {
        let output = string(Self.iosTree, .summary)

        #expect(output == """
        # ios IOS-UDID 402x874 @3x portrait 0°
        application "Playground" (0,0 402x874)
          button "S" id=size-s value="Small" (16,769 85x36)
          [off-screen below] 1 item: "Far below"

        """)
    }

    @Test("fields come out in schema order whatever order they were typed in")
    func fieldsInSchemaOrder() throws {
        let fields = try UITreeRenderOptions.parseFields("frame, label,role,label")
        let output = string(Self.iosTree, UITreeRenderOptions(flat: true, fields: fields, compact: true))
        let first = try #require(output.split(separator: "\n").first)

        #expect(fields == [.role, .label, .frame])
        #expect(first.contains(#"{"index":0,"parent":null,"depth":0,"role":"application","label":"Playground","frame":{"#))
        #expect(!output.contains("\"native\""))
    }

    @Test("nested JSON with fields keeps children")
    func nestedFieldsKeepChildren() throws {
        let output = string(Self.iosTree, UITreeRenderOptions(fields: [.label]))
        let root = try #require((try json(output)["roots"] as? [[String: Any]])?.first)

        #expect(Set(root.keys) == ["label", "children"])
        #expect((root["children"] as? [Any])?.count == 1)
    }

    @Test("text with fields always shows the role")
    func textFieldsKeepRole() {
        let output = string(Self.iosTree, UITreeRenderOptions(format: .text, fields: [.id]))

        #expect(output.contains("\n    button id=size-s\n"))
    }

    @Test("compact JSON parses to the same value as pretty JSON", arguments: [iosTree, androidTree])
    func compactMatchesPretty(tree: UITree) throws {
        let compact = string(tree, UITreeRenderOptions(compact: true))
        let pretty = try JSONSerialization.jsonObject(with: tree.jsonData()) as? NSDictionary

        #expect(compact.filter { $0 == "\n" }.count == 1)
        #expect(compact.contains("\"id\":null"))
        #expect(try JSONSerialization.jsonObject(with: Data(compact.utf8)) as? NSDictionary == pretty)
    }

    @Test("--summary equals --flat --on-screen --labelled --format text --max-bytes 16384")
    func summaryExpands() throws {
        let expanded = try cliOptions(["--flat", "--on-screen", "--labelled", "--format", "text", "--max-bytes", "16384"])

        #expect(try cliOptions(["--summary"]) == expanded)
        #expect(expanded == .summary)
    }

    @Test("--summary takes extra filters and an explicit format")
    func summaryCombines() throws {
        let options = try cliOptions(["--summary", "--actionable", "--format", "ndjson", "--compact"])

        #expect(options.format == .ndjson)
        #expect(options.flat && options.filter == UITreeFilter(onScreen: true, labelled: true, actionable: true))
        #expect(options.compact)
    }

    @Test("an unknown field names itself and lists the valid keys")
    func unknownField() {
        let error = #expect(throws: UIFieldError.self) {
            try UITreeRenderOptions.parseFields("role,labels")
        }
        #expect(error?.description == "Unknown field 'labels' in --fields. Use: role, id, label, value, frame, enabled, state, native.")
        #expect(DescribeUIOutputOptions.message(for: CLIParseProbe.error(["--fields", "role,labels"]))
            == "Unknown field 'labels' in --fields. Use: role, id, label, value, frame, enabled, state, native.")
    }

    @Test("--summary defaults to 16384 bytes, --format text has no default budget, --max-bytes 0 lifts it")
    func maxBytesDefaults() throws {
        #expect(try cliOptions(["--summary"]).maxBytes == 16384)
        #expect(try cliOptions(["--format", "text"]).maxBytes == nil)
        #expect(try cliOptions(["--summary", "--max-bytes", "0"]).maxBytes == nil)
        #expect(try cliOptions(["--format", "text", "--max-bytes", "2000"]).maxBytes == 2000)
        #expect(try cliOptions(["--summary", "--format", "json"]).maxBytes == nil)
    }

    @Test("--max-bytes is refused with JSON and below 512, as a usage error")
    func maxBytesRefused() {
        let cases: [([String], String)] = [
            (["--max-bytes", "4096"], "--max-bytes applies to text output only."),
            (["--summary", "--format", "ndjson", "--max-bytes", "4096"], "--max-bytes applies to text output only."),
            (["--summary", "--max-bytes", "511"], "--max-bytes must be 0 (no limit) or at least 512."),
        ]
        for (arguments, message) in cases {
            let error = CLIParseProbe.error(arguments)
            #expect(DescribeUIOutputOptions.message(for: error) == message)
            #expect(DescribeUIOutputOptions.exitCode(for: error).rawValue == 64)
        }
    }

    @Test("--compact is rejected for text output, including --summary")
    func compactRejectsText() {
        for arguments in [["--format", "text", "--compact"], ["--summary", "--compact"]] {
            #expect(DescribeUIOutputOptions.message(for: CLIParseProbe.error(arguments)) == "--compact applies to json and ndjson only.")
        }
    }
}

private enum CLIParseProbe {
    static func error(_ arguments: [String]) -> Error {
        do {
            _ = try DescribeUIOutputOptions.parse(arguments)
            return CancellationError()
        } catch {
            return error
        }
    }
}
