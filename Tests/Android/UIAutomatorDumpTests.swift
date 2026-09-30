import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("uiautomator dump")
struct UIAutomatorDumpTests {
    private static func result(_ status: Int32, stdout: String = "", stderr: String = "") -> AdbShellResult {
        AdbShellResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    @Test("results are classified into a tree or an actionable failure", arguments: [
        (result(0, stdout: "<?xml version='1.0' ?><hierarchy rotation=\"0\"/>"), UIAutomatorDump.Outcome.tree("<?xml version='1.0' ?><hierarchy rotation=\"0\"/>")),
        (result(3, stderr: "ERROR: could not get idle state.\n"), .idleTimeout),
        (result(137), .busy),
        (result(134), .busy),
        (result(3), .busy),
        (result(3, stderr: "ERROR: null root node returned by UiTestAutomationBridge.\n"), .noWindow),
        (result(3, stderr: "Killed\nmore\n"), .failed("Killed")),
        (result(1), .failed("exit status 1")),
    ])
    func classify(result: AdbShellResult, expected: UIAutomatorDump.Outcome) {
        #expect(UIAutomatorDump.classify(result) == expected)
    }

    @Test("the dump file name is unique per process and call, and the script quotes it")
    func scriptAndPath() {
        let path = UIAutomatorDump.devicePath(pid: 4242, counter: 3)
        #expect(path == "/data/local/tmp/offsider-ui-4242-3.xml")
        let script = UIAutomatorDump.script(path: path)
        #expect(script.hasPrefix("f='/data/local/tmp/offsider-ui-4242-3.xml'; out=$(uiautomator dump --compressed \"$f\" 2>&1);"))
        #expect(script.contains("rm -f \"$f\""))
        #expect(script.hasSuffix("exit 3; fi"))
    }

    @Test("attributes, nesting, rotation, entities and non-ASCII text survive parsing")
    func parse() throws {
        let xml = """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="1"><node index="0" text="" class="android.widget.FrameLayout" bounds="[0,0][2424,1080]"><node index="0" text="Fish &amp; chips &quot;now&quot;&#10;line two" content-desc="héllo 日本 🙂" class="android.widget.TextView" bounds="[1,2][3,4]" /></node></hierarchy>
        """
        let hierarchy = try UIAutomatorDump.parse(xml)
        #expect(hierarchy.rotation == 1)
        #expect(hierarchy.nodes.count == 1)
        let child = try #require(hierarchy.nodes.first?.children.first)
        #expect(child["text"] == "Fish & chips \"now\"\nline two")
        #expect(child["content-desc"] == "héllo 日本 🙂")
        #expect(child["bounds"] == "[1,2][3,4]")
    }

    @Test("output that is not a hierarchy throws")
    func notAHierarchy() {
        #expect(throws: UIAutomatorDump.ParseFailure.self) { try UIAutomatorDump.parse("<?xml version='1.0' ?><other/>") }
        #expect(throws: UIAutomatorDump.ParseFailure.self) { try UIAutomatorDump.parse("<hierarchy><node>") }
    }
}
