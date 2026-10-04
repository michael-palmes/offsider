import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android secure text")
@MainActor
struct AndroidSecureTextTests {
    static let sentinel = "S3NT1NEL"
    static let attributes = #"package="p" content-desc="" checkable="false" checked="false" enabled="true" focusable="true" scrollable="false" long-clickable="false" selected="false""#

    static func xml(_ body: String) -> String {
        """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" \(attributes) clickable="false" focused="false" password="false" bounds="[0,0][1080,2424]" hint="">\(body)</node></hierarchy>
        """
    }

    static func passwordNode(text: String, hint: String = "Password", focused: Bool = false) -> String {
        #"<node index="0" text="\#(text)" resource-id="password-field" class="android.widget.EditText" \#(attributes) clickable="true" focused="\#(focused)" password="true" bounds="[42,510][1038,626]" hint="\#(hint)" />"#
    }

    static func roots(_ body: String) throws -> [UINode] {
        AndroidTreeMapping.roots(from: try UIAutomatorDump.parse(xml(body)), scale: 2.625)
    }

    static func rendered(_ roots: [UINode]) -> String {
        String(decoding: UITree(platform: .android, device: "emulator-5556", roots: roots).jsonData(), as: UTF8.self)
    }

    @Test("a password node's value and native text are masked, one bullet per character")
    func passwordMasked() throws {
        let roots = try Self.roots(Self.passwordNode(text: Self.sentinel))
        let field = try #require(roots.flatMap { $0.flattened() }.first { $0.id == "password-field" })

        #expect(field.role == .secureTextField)
        #expect(field.value == "••••••••")
        guard case .android(let native) = field.native else { Issue.record("not Android"); return }
        #expect(native.text == "••••••••")
        #expect(native.hint == "Password")
        #expect(!Self.rendered(roots).contains(Self.sentinel))
    }

    @Test("a password field showing its hint, or nothing, reads as empty")
    func hintIsEmpty() throws {
        for text in ["Password", ""] {
            let roots = try Self.roots(Self.passwordNode(text: text))
            let field = try #require(roots.flatMap { $0.flattened() }.first { $0.id == "password-field" })
            #expect(field.value == nil)
        }
    }

    @Test("a clickable parent never takes a password child's text as its label")
    func parentLabel() throws {
        let child = Self.passwordNode(text: Self.sentinel).replacingOccurrences(of: #"clickable="true""#, with: #"clickable="false""#)
        let body = #"<node index="0" text="" resource-id="row" class="android.view.ViewGroup" \#(Self.attributes) clickable="true" focused="false" password="false" bounds="[0,500][1080,640]" hint=""><node index="0" text="Sign in" resource-id="" class="android.widget.TextView" \#(Self.attributes) clickable="false" focused="false" password="false" bounds="[0,500][300,560]" hint="" />\#(child)</node>"#
        let roots = try Self.roots(body)
        let row = try #require(roots.flatMap { $0.flattened() }.first { $0.id == "row" })

        #expect(row.label == "Sign in")
        #expect(!Self.rendered(roots).contains(Self.sentinel))
    }

    @Test("helper password text never reaches the tree")
    func helperPassword() throws {
        let field = #"{"i":4,"class":"android.widget.EditText",\#(HelperTreeMappingTests.package),"resourceId":"password-field","text":"\#(Self.sentinel)","hint":"Password","bounds":[42,510,1038,626],"clickable":true,"focusable":true,"focused":true,"editable":true,"password":true}"#
        let roots = HelperTreeMapping.roots(from: try HelperTreeMappingTests.dump(HelperTreeMappingTests.appWindow(field)), scale: 2.625, pid: 1).roots
        let node = try #require(roots.flatMap { $0.flattened() }.first { $0.id == "password-field" })

        #expect(node.value == "••••••••")
        #expect(!Self.rendered(roots).contains(Self.sentinel))
        let text = UITreeRenderer.render(UITree(platform: .android, device: "e", roots: roots), UITreeRenderOptions(format: .text, fields: [.native, .value, .label]))
        #expect(!String(decoding: text, as: UTF8.self).contains(Self.sentinel))
    }

    @Test("pasting into a focused password field is refused before the clipboard is touched")
    func securePasteRefused() async throws {
        let rig = try AndroidGrpcInputTests.rig(
            emulator: FakeEmulator(clipboard: "saved"),
            environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"],
            uiautomatorDump: Self.xml(Self.passwordNode(text: "", focused: true))
        )
        let session = try #require(try await rig.backend.openInputSession(for: AndroidGrpcTextTests.device) as? any TextInputSession)

        let error = await #expect(throws: AndroidError.self) { try await session.typeText("pässwörd") }
        #expect(error?.kind == .securePasteRefused)
        #expect(error?.message.contains("type --replace") == true)
        #expect(!(error?.message.contains("pässwörd") ?? true))
        #expect(rig.emulator.calls.isEmpty)
        #expect(!rig.adbScripts.contains("input keyevent 279"))
    }

    @Test("pasting into a focused plain field still pastes")
    func plainPasteAllowed() async throws {
        let plain = Self.passwordNode(text: "", focused: true).replacingOccurrences(of: #"password="true""#, with: #"password="false""#)
        let rig = try AndroidGrpcInputTests.rig(
            emulator: FakeEmulator(clipboard: "saved"),
            environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"],
            uiautomatorDump: Self.xml(plain)
        )
        let session = try #require(try await rig.backend.openInputSession(for: AndroidGrpcTextTests.device) as? any TextInputSession)
        try await session.typeText("héllo")

        #expect(rig.emulator.calls == [.getClipboard, .setClipboard("héllo"), .setClipboard("saved")])
    }

    @Test("a failed adb input names the character count, never the typed text")
    func adbLabel() async throws {
        let rig = try AndroidGrpcInputTests.rig(
            environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb"],
            failingScript: { $0.hasPrefix("input text") }
        )
        let session = try #require(try await rig.backend.openInputSession(for: AndroidGrpcTextTests.device) as? any TextInputSession)

        let error = await #expect(throws: AndroidError.self) { try await session.typeText(Self.sentinel) }
        #expect(error?.kind == .inputFailed)
        #expect(error?.message.contains("8 characters") == true)
        #expect(!(error?.message.contains(Self.sentinel) ?? true))
    }
}
