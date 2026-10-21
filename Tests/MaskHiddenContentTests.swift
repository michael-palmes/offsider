import CoreGraphics
import Foundation
@testable import OffsiderAndroid
import OffsiderCore
import Testing
@testable import Offsider

/// An Android backend whose mask read sees a row its plain read leaves out, as content hidden from accessibility behind a sheet is.
private final class HiddenRowBackend: FakeDeviceBackend, MaskTreeReading {
    let maskTreeValue: UITree
    private(set) var maskReads = 0

    init(plain: UITree, mask: UITree) throws {
        maskTreeValue = mask
        super.init(platform: plain.platform, trees: [plain], screenshots: [try ScreenshotMaskTests.whitePNG()], screen: ScreenshotMaskTests.screen)
    }

    func maskTree(for id: DeviceID) async throws -> UITree {
        maskReads += 1
        return maskTreeValue
    }
}

@Suite("Masks over content hidden from the tree")
@MainActor
struct MaskHiddenContentTests {
    static let address = FakeUI.node(.text, label: "Address bc1q...7k3m", frame: FakeUI.frame(20, 100, 300, 30))
    static let close = FakeUI.node(.button, id: "close", label: "Close Sheet", frame: FakeUI.frame(20, 700, 300, 44))

    static func modal(_ children: [UINode]) -> UITree {
        var tree = FakeUI.tree(platform: .android, width: 390, height: 844, label: nil, children)
        tree.windows = [
            UIWindowInfo(id: 1, kind: "application", layer: 0, title: "Playground", active: false, focused: false, package: "com.example.app", bounds: FakeUI.frame(0, 0, 390, 844)),
            UIWindowInfo(id: 2, kind: "application", layer: 1, title: nil, active: true, focused: true, package: "com.example.app", bounds: FakeUI.frame(0, 0, 390, 844)),
        ]
        return tree
    }

    @Test("a screenshot paints text only the mask read sees, and never takes the plain read")
    func maskReadPaints() async throws {
        let backend = try HiddenRowBackend(plain: FakeUI.tree(width: 390, height: 844, [Self.close]), mask: FakeUI.tree(width: 390, height: 844, [Self.address, Self.close]))
        let (report, image, _) = try await DeviceActivityLedger.$current.withValue(DeviceActivityLedger()) {
            try await ScreenshotMaskTests.capture(["--mask-text", #"\.\.\."#], on: backend, environment: [:])
        }

        #expect(report.maskedBy?[.text] == 1)
        #expect(report.maskUnmatched.isEmpty)
        #expect(ScreenshotMaskTests.point(image, 170, 115) == ScreenshotMaskTests.black)
        #expect(backend.maskReads == 1 && backend.treeReads == 0)
    }

    @Test("over an Android modal window the report and stderr say masks could not see behind it")
    func modalUnproven() async throws {
        let capture = ConsoleCapture()
        let backend = try HiddenRowBackend(plain: Self.modal([Self.close]), mask: Self.modal([Self.close]))
        let (report, _, _) = try await Console.$current.withValue(AgentOutputTests.agentConsole(capture)) {
            try await ScreenshotMaskTests.capture(["--mask-text", #"\.\.\."#], on: backend, environment: [:])
        }

        #expect(report.maskUnproven == "modal")
        #expect(report.jsonLine().contains(#""maskUnproven":"modal""#))
        #expect(capture.err.contains("(maskUnproven)"))
    }

    @Test("an app window, an iOS tree and an empty LogBox dialog leave masks proven")
    func proven() {
        #expect(ScreenCapture.unproven(Self.modal([Self.close])) == "modal")
        #expect(ScreenCapture.unproven(LogBoxTrees.androidTree([Self.close], title: "Playground")) == nil)
        #expect(ScreenCapture.unproven(FakeUI.tree([Self.close])) == nil)
        #expect(ScreenCapture.unproven(LogBoxTrees.androidTree([], title: nil)) == nil)
        #expect(ScreenCapture.unproven(LogBoxTrees.androidInspector()) == nil)
    }

    @Test("the Android mask read asks the helper for views not important for accessibility, and the tree cache never sees it")
    func androidMaskRead() async throws {
        let rig = try HelperRig()
        let ledger = DeviceActivityLedger()
        try await DeviceActivityLedger.$current.withValue(ledger) {
            _ = try await rig.backend.maskTree(for: HelperRig.device)
            #expect(ledger.activities.isEmpty)
            _ = try await rig.read()
            #expect(ledger.activities.count == 1)
        }
        let dumps = rig.device.frames.filter { $0.op == "dump" }.map(\.json)

        #expect(dumps.count == 2)
        #expect(dumps.first?.contains(#""notImportant":true"#) == true)
        #expect(dumps.last?.contains(#""notImportant":false"#) == true)
    }

    @Test("without the helper the mask read is an uncompressed uiautomator dump")
    func uiautomatorMaskRead() {
        let script = UIAutomatorDump.script(path: "/data/local/tmp/offsider-ui-1-1.xml", compressed: false)
        #expect(script.contains(#"uiautomator dump "$f""#))
        #expect(!script.contains("--compressed"))
    }
}
