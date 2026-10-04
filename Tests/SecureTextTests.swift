import CoreGraphics
import FBControlCore
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Secure text")
@MainActor
struct SecureTextTests {
    static let sentinel = "S3NT1NEL"
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func passwordField(value: String? = "••••••••", frame: UIFrame? = FakeUI.frame(16, 270, 361, 44), focused: Bool? = nil, platform: DevicePlatform = .ios) -> UINode {
        FakeUI.node(.secureTextField, id: "password-field", label: "Password", value: value, frame: frame, state: UIState(focused: focused), platform: platform)
    }

    // MARK: - Masking rule

    @Test("a secure value becomes one bullet per character")
    func bullets() {
        #expect(SecureText.masked("hunter2") == "•••••••")
        #expect(SecureText.masked("a🙂e\u{301}") == "•••")
        #expect(SecureText.masked("•••") == "•••")
    }

    @Test("an empty or missing secure value stays empty")
    func emptyStaysEmpty() {
        #expect(SecureText.masked(nil) == nil)
        #expect(SecureText.masked("") == nil)
    }

    @Test("secure focus on Android needs a focused password node")
    func androidFocus() {
        let focused = FakeUI.tree(platform: .android, [Self.passwordField(focused: true, platform: .android)])
        let unfocused = FakeUI.tree(platform: .android, [Self.passwordField(focused: false, platform: .android)])
        #expect(focused.secureFocus == .secureFocused)
        #expect(unfocused.secureFocus == .none)
    }

    @Test("secure focus on iOS is possible when a keyboard and a secure field are on screen")
    func iosFocus() {
        let withKeyboard = FakeUI.tree([Self.passwordField(), FakeUI.node(.keyboard, frame: FakeUI.frame(0, 500, 402, 300))])
        #expect(withKeyboard.secureFocus == .securePossible)
        #expect(FakeUI.tree([Self.passwordField()]).secureFocus == .none)
    }

    // MARK: - iOS mapping

    @Test("a SecureTextField's value is masked and keeps its length")
    func iosSecureMasked() throws {
        let json = #"[{"type":"Application","frame":{"x":0,"y":0,"width":402,"height":874},"children":[{"type":"SecureTextField","AXUniqueId":"password-field","AXLabel":"Password","AXValue":"\#(Self.sentinel)","frame":{"x":16,"y":270,"width":361,"height":44}}]}]"#
        let roots = try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8))
        let field = try #require(roots.flatMap { $0.flattened() }.first { $0.id == "password-field" })
        let encoded = String(decoding: UITree(platform: .ios, device: "d", roots: roots).jsonData(), as: UTF8.self)

        #expect(field.value == "••••••••")
        #expect(field.label == "Password")
        #expect(!encoded.contains(Self.sentinel))
    }

    @Test("a SwiftUI SecureField, reported as a TextField with the secure subrole, is masked")
    func iosSecureSubrole() throws {
        let json = #"{"type":"TextField","role":"AXTextField","subrole":"AXSecureTextField","role_description":"secure text field","AXValue":"\#(Self.sentinel)"}"#
        let roots = try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8))
        #expect(roots.first?.role == .secureTextField)
        #expect(roots.first?.value == "••••••••")
    }

    @Test("a TextField's value is not masked")
    func iosPlainKept() throws {
        let json = #"{"type":"TextField","AXUniqueId":"name","AXValue":"\#(Self.sentinel)"}"#
        let roots = try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8))
        #expect(roots.first?.value == Self.sentinel)
    }

    // MARK: - Verify summaries

    @Test("a secure value change is reported without either value")
    func secureChangeSummary() {
        func snapshot(_ value: String) -> AccessibilitySnapshot {
            AccessibilitySnapshot(roots: [AccessibilitySnapshot.Node(type: "Application", children: [
                AccessibilitySnapshot.Node(type: "SecureTextField", identifier: "password-field", value: value, isSecure: true),
            ])])
        }
        let result = ChangeDetector().compare(snapshot("abc"), snapshot("abcd"))
        guard case .changed(let summary) = result else { Issue.record("expected a change, got \(result)"); return }

        #expect(summary == "value of password-field changed (secure field)")
        #expect(!summary.contains("abc"))
    }

    // MARK: - Selectors

    @Test("--value never matches a secure field, even with the bullets")
    func valueNeverMatches() {
        let roots = FakeUI.tree([Self.passwordField()]).roots
        for value in ["••••••••", Self.sentinel] {
            #expect(throws: (any Error).self) {
                try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .value(value))
            }
        }
    }

    @Test("not-found suggestions never list a secure field's value")
    func suggestionsSkipSecure() {
        let roots = FakeUI.tree([Self.passwordField(value: "•••••")]).roots
        do {
            _ = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .value("••••"))
            Issue.record("expected not found")
        } catch {
            #expect(!error.localizedDescription.contains("•••••"))
        }
    }

    @Test("--id and --label still find a secure field")
    func idAndLabelFind() throws {
        let roots = FakeUI.tree([Self.passwordField()]).roots
        let byID = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .id("password-field"))
        let byLabel = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Password"))
        #expect(byID.x == 196.5 && byID.y == 292)
        #expect(byLabel.x == 196.5 && byLabel.y == 292)
    }

    // MARK: - Type logging

    private final class LogLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private static func capturingLogger() -> (OffsiderLogger, LogLines) {
        let lines = LogLines()
        let consumer = FBBlockDataConsumer.synchronousLineConsumer { lines.append($0) }
        return (OffsiderLogger(loggers: [FBControlCoreLoggerFactory.logger(to: consumer)]), lines)
    }

    @Test("type logs only the character count")
    func typeLogsCount() async throws {
        let backend = FakeDeviceBackend(trees: [])
        let (logger, lines) = Self.capturingLogger()
        try await Type.parse([Self.sentinel, "--device", Self.device.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: logger)

        #expect(lines.all.contains { $0.contains("Typing 8 characters") })
        #expect(!lines.all.contains { $0.contains(Self.sentinel) })
    }

    @Test("an unsupported character is reported by position, not by the character")
    func unsupportedByPosition() async throws {
        let backend = FakeDeviceBackend(trees: [])
        let (logger, lines) = Self.capturingLogger()
        let text = Self.sentinel + "£"
        let error = await #expect(throws: TextToHIDEvents.TextConversionError.self) {
            try await Type.parse([text, "--device", Self.device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: logger)
        }
        let message = error?.localizedDescription ?? ""

        #expect(message.contains("position 9 (of 9)"))
        #expect(!message.contains(Self.sentinel) && !message.contains("£"))
        #expect(!lines.all.contains { $0.contains(Self.sentinel) || $0.contains("£") })
        #expect(backend.session.calls.isEmpty)
    }

    @Test("typed text never appears on stdout or stderr")
    func typedTextNeverPrinted() async throws {
        let unknown = TestDevices.simulatorUDID()
        defer { TestDevices.removePrivateFiles(platform: .ios, id: unknown) }
        for command in [
            "type \(Self.sentinel) --device \(unknown)",
            "batch --json --step 'type \(Self.sentinel)' --device \(unknown)",
            "type -\(Self.sentinel) --device \(unknown)",
            "type -\(Self.sentinel) --verify --json --device \(unknown)",
            "batch --json --step 'type -\(Self.sentinel)' --device \(unknown)",
        ] {
            let result = try await TestHelpers.runOffsiderCommandAllowFailure(command)
            #expect(result.exitCode != 0)
            #expect(!result.output.contains(Self.sentinel), "\(command) printed the text: \(result.output)")
        }
    }

    // MARK: - Batch records

    private static func batch(_ steps: [String], on backend: FakeDeviceBackend, maskSecure: Bool = false) async throws -> (records: [BatchStepRecord], out: String, err: String) {
        let context = BatchContext(
            backend: backend, device: device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200, maskSecure: maskSecure
        )
        var out = ""
        var err = ""
        let output = BatchOutput(json: true, write: { out += $0 }, writeError: { err += $0 })
        let records = try await Batch.runSteps(steps, context: context, session: backend.session, continueOnError: true, output: output, logger: OffsiderLogger())
        return (records, out, err)
    }

    @Test("batch --json masks the text of a type step and keeps its flags")
    func batchMasksType() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree()])
        let result = try await Self.batch(["type \(Self.sentinel) --replace"], on: backend)

        #expect(result.records.map(\.line) == ["type <8 characters> --replace"])
        #expect(!result.out.contains(Self.sentinel))
    }

    @Test("a type step's errors never echo its text")
    func batchTypeErrors() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree()])
        var stderr = ""
        do {
            _ = try await Self.batch(["type \(Self.sentinel) extra", "type '\(Self.sentinel)£'", "type 'unterminated \(Self.sentinel)"], on: backend)
            Issue.record("expected the batch to fail")
        } catch let error as ReportedFailure {
            stderr = error.userFacingDescription
        }

        #expect(stderr.contains("Step 1 failed") && stderr.contains("Step 2 failed") && stderr.contains("Step 3 failed"))
        #expect(!stderr.contains(Self.sentinel))
    }

    @Test("redacted lines count characters and keep a file path")
    func redactedLines() {
        #expect(BatchStepRedaction.redactedLine("type a", tokens: ["type", "a"]) == "type <1 character>")
        #expect(BatchStepRedaction.redactedLine("type --file in.txt", tokens: ["type", "--file", "in.txt"]) == "type --file in.txt")
        #expect(BatchStepRedaction.redactedLine("type 'x", tokens: nil) == "type <unparsed>")
        #expect(BatchStepRedaction.redactedLine("tap --id a", tokens: ["tap", "--id", "a"]) == "tap --id a")
    }

    @Test("a dash-leading type text is text, and an option's value stays with its option")
    func redactionUsesTypeOptions() {
        #expect(BatchStepRedaction.redactedLine("", tokens: ["type", "-Pa55word"]) == "type <9 characters>")
        #expect(BatchStepRedaction.textTokens(["type", "-Pa55word"]) == ["-Pa55word"])
        #expect(BatchStepRedaction.redactedLine("", tokens: ["type", "hello", "--verify-timeout", "3"]) == "type <5 characters> --verify-timeout 3")
        #expect(BatchStepRedaction.textTokens(["type", "hello", "--verify-timeout", "3"]) == ["hello"])
        #expect(BatchStepRedaction.redactedLine("", tokens: ["type", "--", "--replace"]) == "type -- <9 characters>")
        #expect(BatchStepRedaction.textTokens(["type", "--retries=2", "x"]) == ["x"])
    }

    @Test("the redaction's option names are exactly type's options")
    func redactionMatchesTypeHelp() throws {
        let help = Type.helpMessage(columns: 400)
        let regex = try NSRegularExpression(pattern: "(?<![\\w-])(--[a-z][a-z-]*|-h)\\b(?: <[^>]+>)?")
        var flags: Set<String> = []
        var values: Set<String> = []
        for match in regex.matches(in: help, range: NSRange(help.startIndex..., in: help)) {
            let text = String(help[Range(match.range, in: help)!])
            let name = String(text.split(separator: " ")[0])
            if text.contains("<") { values.insert(name) } else { flags.insert(name) }
        }
        flags.subtract(values)
        #expect(values == BatchStepRedaction.valueOptions)
        #expect(flags == BatchStepRedaction.flags)
    }

    @Test("a batch type step whose text starts with a dash keeps it out of records and errors")
    func batchDashText() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree()])
        var stderr = ""
        var out = ""
        do {
            let result = try await Self.batch(["type -\(Self.sentinel)", "type ok --verify-timeout 3"], on: backend)
            out = result.out
        } catch let error as ReportedFailure {
            stderr = error.userFacingDescription
        }
        #expect(!out.contains(Self.sentinel))
        #expect(!stderr.contains(Self.sentinel))
    }

    @Test("a batch type step after -- types dash-leading text")
    func batchTerminatedText() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree()])
        let result = try await Self.batch(["type -- -\(Self.sentinel)"], on: backend)
        #expect(result.records.map(\.ok) == [true])
        #expect(result.records.map(\.line) == ["type -- <9 characters>"])
    }

    // MARK: - Screenshot masking

    private static let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)

    private static func whitePNG() throws -> Data {
        try ScreenImage.encode(TestImages.make(width: 1170, height: 2532, background: 255), as: .png)
    }

    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        }
        return Array(bytes.prefix(3))
    }

    private static func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("offsider-mask-\(UUID().uuidString).png").path
    }

    @Test("masking paints rectangles opaque black, rounded outward")
    func paintsBlack() throws {
        let image = TestImages.make(width: 1170, height: 2532, background: 255)
        let masked = try ScreenImage.masked(image, pixelRects: [CGRect(x: 10.4, y: 20.6, width: 5, height: 5)])

        #expect(Self.pixel(masked, 10, 20) == [0, 0, 0])
        #expect(Self.pixel(masked, 15, 25) == [0, 0, 0])
        #expect(Self.pixel(masked, 9, 19) == [255, 255, 255])
    }

    @Test("screenshot --mask-secure blacks out a secure field at device scale")
    func screenshotMasks() async throws {
        let path = Self.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 390, height: 844, [Self.passwordField()])], screenshots: [try Self.whitePNG()], screen: Self.screen)

        let report = try await Screenshot.parse(["--output", path, "--device", Self.device.rawValue])
            .take(ScreenshotRequest(), on: DeviceRouter.Route(backend: backend, device: Self.device), masking: true)
        let written = try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: path)))

        #expect(report.masked == 1)
        #expect(report.jsonLine().contains(#""masked":1"#))
        #expect(Self.pixel(written, 600, 870) == [0, 0, 0])
        #expect(Self.pixel(written, 600, 720) == [255, 255, 255])
        #expect(backend.treeReads == 1)
    }

    @Test("a secure field without a frame withholds the screenshot and writes no file")
    func withheldWithoutFrame() async throws {
        let path = Self.temporaryPath()
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 390, height: 844, [Self.passwordField(frame: nil)])], screenshots: [try Self.whitePNG()], screen: Self.screen)

        let error = await #expect(throws: MaskUnproven.self) {
            try await Screenshot.parse(["--output", path, "--device", Self.device.rawValue])
                .take(ScreenshotRequest(), on: DeviceRouter.Route(backend: backend, device: Self.device), masking: true)
        }
        #expect(error?.localizedDescription.contains("the screenshot was withheld") == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("screenshot without --mask-secure reads no tree")
    func plainReadsNoTree() async throws {
        let path = Self.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 390, height: 844, [Self.passwordField()])], screenshots: [try Self.whitePNG()], screen: Self.screen)

        let report = try await Screenshot.parse(["--output", path, "--device", Self.device.rawValue])
            .take(ScreenshotRequest(), on: DeviceRouter.Route(backend: backend, device: Self.device), masking: false)

        #expect(backend.treeReads == 0)
        #expect(report.masked == nil)
        #expect(!report.jsonLine().contains("masked"))
    }

    @Test("OFFSIDER_MASK_SECURE=1 turns masking on by default")
    func environmentDefault() {
        #expect(Screenshot.masksSecure(flag: false, environment: ["OFFSIDER_MASK_SECURE": "1"]))
        #expect(!Screenshot.masksSecure(flag: false, environment: [:]))
        #expect(Screenshot.masksSecure(flag: true, environment: [:]))
    }

    @Test("batch --mask-secure reuses the cached tree")
    func batchReusesTree() async throws {
        let path = Self.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 390, height: 844, [Self.passwordField()])], screenshots: [try Self.whitePNG()], screen: Self.screen)

        let result = try await Self.batch(["assert --id password-field", "screenshot --output \(path)"], on: backend, maskSecure: true)

        let written = try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: path)))

        #expect(result.records.filter { !$0.ok }.isEmpty)
        #expect(backend.treeReads == 1)
        #expect(Self.pixel(written, 600, 870) == [0, 0, 0])
    }
}
