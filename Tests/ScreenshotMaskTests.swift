import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Screenshot masks")
@MainActor
struct ScreenshotMaskTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)
    static let black: [UInt8] = [0, 0, 0]
    static let white: [UInt8] = [255, 255, 255]

    static func whitePNG() throws -> Data {
        try ScreenImage.encode(TestImages.make(width: 1170, height: 2532, background: 255), as: .png)
    }

    nonisolated static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
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

    /// The pixel at a point of the 390 x 844 pt screen, captured at 3x.
    static func point(_ image: CGImage, _ x: Double, _ y: Double) -> [UInt8] {
        pixel(image, Int(x * 3), Int(y * 3))
    }

    static func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("offsider-mask-\(UUID().uuidString).png").path
    }

    static func backend(_ children: [UINode]) throws -> FakeDeviceBackend {
        FakeDeviceBackend(trees: [FakeUI.tree(width: 390, height: 844, children)], screenshots: [try whitePNG()], screen: screen)
    }

    /// Runs `screenshot` with `arguments`, returning the report and the written image.
    static func capture(_ arguments: [String], on backend: FakeDeviceBackend) async throws -> (report: ScreenshotReport, image: CGImage, path: String) {
        let path = temporaryPath()
        let command = try Screenshot.parse(["--output", path, "--device", device.rawValue] + arguments)
        let report = try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: device), masks: try command.maskPlan(environment: [:]))
        let image = try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        return (report, image, path)
    }

    // MARK: - Painting

    @Test("masking paints rectangles opaque black, rounded outward")
    func paintsBlack() throws {
        let image = TestImages.make(width: 1170, height: 2532, background: 255)
        let masked = try ScreenImage.masked(image, pixelRects: [CGRect(x: 10.4, y: 20.6, width: 5, height: 5)])

        #expect(Self.pixel(masked, 10, 20) == Self.black)
        #expect(Self.pixel(masked, 15, 25) == Self.black)
        #expect(Self.pixel(masked, 9, 19) == Self.white)
    }

    @Test("--mask-secure blacks out a secure field at device scale")
    func secureMasks() async throws {
        let backend = try Self.backend([SecureTextTests.passwordField()])
        let result = try await Self.capture(["--mask-secure"], on: backend)
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(result.report.masked == 1)
        #expect(result.report.jsonLine().contains(#""masked":1,"maskedBy":{"secure":1}"#))
        #expect(Self.pixel(result.image, 600, 870) == Self.black)
        #expect(Self.pixel(result.image, 600, 720) == Self.white)
        #expect(backend.treeReads == 1)
    }

    @Test("--mask-id paints every element with that id")
    func everyIDMatch() async throws {
        let backend = try Self.backend([
            FakeUI.node(.text, id: "profile-email", label: "a", frame: FakeUI.frame(16, 100, 200, 40)),
            FakeUI.node(.text, id: "profile-email", label: "b", frame: FakeUI.frame(16, 300, 200, 40)),
            FakeUI.node(.text, id: "other", label: "c", frame: FakeUI.frame(16, 500, 200, 40)),
        ])
        let result = try await Self.capture(["--mask-id", "profile-email"], on: backend)
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(result.report.maskedBy == [.id: 2])
        #expect(Self.point(result.image, 116, 120) == Self.black)
        #expect(Self.point(result.image, 116, 320) == Self.black)
        #expect(Self.point(result.image, 116, 520) == Self.white)
    }

    @Test("--mask-label matches after folding quotes, as --label does")
    func foldedLabel() async throws {
        let backend = try Self.backend([FakeUI.node(.button, label: "Don\u{2019}t Allow", frame: FakeUI.frame(16, 100, 200, 40))])
        let result = try await Self.capture(["--mask-label", "Don't Allow"], on: backend)
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(result.report.maskedBy == [.label: 1])
        #expect(Self.point(result.image, 116, 120) == Self.black)
    }

    @Test("--mask-emails paints the field showing the address, not the row around it")
    func emailLeafNotParent() async throws {
        let field = FakeUI.node(.textField, id: "email", value: "e2e@example.com", frame: FakeUI.frame(16, 120, 200, 30))
        let row = FakeUI.node(.other, label: "Signed in as e2e@example.com", frame: FakeUI.frame(0, 100, 390, 200), children: [field])
        let result = try await Self.capture(["--mask-emails"], on: try Self.backend([row]))
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(result.report.maskedBy == [.emails: 1])
        #expect(Self.point(result.image, 116, 135) == Self.black)
        #expect(Self.point(result.image, 300, 250) == Self.white)
    }

    @Test("--mask-text reads Android hints and content descriptions, case-insensitively")
    func textReadsHints() throws {
        var hinted = FakeUI.node(.textField, frame: FakeUI.frame(0, 0, 10, 10), platform: .android)
        hinted.native = .android(AndroidNativeAttributes(hint: "Search people"))
        var described = FakeUI.node(.image, frame: FakeUI.frame(0, 20, 10, 10), platform: .android)
        described.native = .android(AndroidNativeAttributes(contentDescription: "Photo of SEARCH results"))
        let tree = FakeUI.tree(platform: .android, label: nil, [hinted, described])

        let targets = try MaskPlan(texts: ["search"]).textTargets(in: tree)
        #expect(targets.frames[.text]?.count == 2)
        #expect(targets.unmatched.isEmpty)
    }

    @Test("a secure field's value is never searched")
    func secureValueNeverSearched() throws {
        let secure = UINode(role: .secureTextField, value: "secret@example.com", frame: FakeUI.frame(0, 0, 10, 10), native: .ios(IOSNativeAttributes()))
        let targets = try MaskPlan(texts: ["secret"], emails: true).textTargets(in: FakeUI.tree(label: nil, [secure]))

        #expect(targets.frames[.emails] == [])
        #expect(targets.unmatched == ["--mask-text secret"])
    }

    @Test("email addresses are found, and version strings and bare @ are not", arguments: [
        ("e2e@example.com", true), ("first.last+tag@mail.co.uk", true),
        ("react-native@0.81.0", false), ("https://x.com/a@b", false), ("@handle", false),
        ("expo-dev-client@6.0.0-canary.rc", false), ("user@localhost.local", true), ("a@163.com", true), ("pkg@1.2.3-beta.rc", false),
    ])
    func emailPattern(text: String, found: Bool) throws {
        let regex = try MaskPlan.compile(PersonalData.emailPattern)
        #expect((regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil) == found)
    }

    @Test("--mask-region reads no tree and paints before the --region crop")
    func regionBeforeCrop() async throws {
        let backend = try Self.backend([SecureTextTests.passwordField()])
        let result = try await Self.capture(["--mask-region", "100,100,50,50", "--region", "100,100,100,100"], on: backend)
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(backend.treeReads == 0)
        #expect(result.report.maskedBy == [.region: 1])
        #expect(result.image.width == 300)
        #expect(Self.pixel(result.image, 10, 10) == Self.black)
        #expect(Self.pixel(result.image, 200, 200) == Self.white)
    }

    @Test("a plain screenshot reads no tree and reports no masks")
    func plainReadsNoTree() async throws {
        let backend = try Self.backend([SecureTextTests.passwordField()])
        let result = try await Self.capture([], on: backend)
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(backend.treeReads == 0)
        #expect(result.report.masked == nil)
        #expect(!result.report.jsonLine().contains("masked"))
    }

    // MARK: - Refusals and reports

    @Test("a masked element without a frame withholds the screenshot and writes no file", arguments: [["--mask-secure"], ["--mask-id", "password-field"]])
    func withheldWithoutFrame(arguments: [String]) async throws {
        let path = Self.temporaryPath()
        let backend = try Self.backend([SecureTextTests.passwordField(frame: nil)])
        let command = try Screenshot.parse(["--output", path, "--device", Self.device.rawValue] + arguments)

        let error = await #expect(throws: MaskUnproven.self) {
            try await command.take(ScreenshotRequest(), on: DeviceRouter.Route(backend: backend, device: Self.device), masks: try command.maskPlan(environment: [:]))
        }
        #expect(error?.localizedDescription.contains("the screenshot was withheld") == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a selector that matches nothing is reported and the image is still written")
    func unmatchedStillWrites() async throws {
        let backend = try Self.backend([FakeUI.node(.text, id: "name", label: "Ada", frame: FakeUI.frame(16, 100, 200, 40))])
        let result = try await Self.capture(["--mask-id", "profile-email", "--mask-label", "Ada"], on: backend)
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(result.report.maskUnmatched == ["--mask-id profile-email"])
        #expect(result.report.jsonLine().contains(#""masked":1,"maskedBy":{"id":0,"label":1},"maskUnmatched":["--mask-id profile-email"]"#))
        #expect(FileManager.default.fileExists(atPath: result.path))
    }

    @Test("an invalid --mask-text or --mask-region is a usage error")
    func badMaskArguments() async throws {
        for arguments in ["--mask-text '('", "--mask-region 1,2,3"] {
            let result = try await TestHelpers.runOffsiderCommandSeparated("screenshot \(arguments) --device \(UUID().uuidString)")
            #expect(result.exitCode == 64, "\(arguments): \(result.stderr)")
        }
        #expect(throws: (any Error).self) { try Screenshot.parse(["--mask-region", "1,2,0,4", "--device", "d"]) }
    }

    @Test("OFFSIDER_MASK_SECURE=1 turns masking on by default")
    func environmentDefault() throws {
        #expect(Screenshot.masksSecure(flag: false, environment: ["OFFSIDER_MASK_SECURE": "1"]))
        #expect(!Screenshot.masksSecure(flag: false, environment: [:]))
        #expect(Screenshot.masksSecure(flag: true, environment: [:]))
        #expect(try Screenshot.parse(["--device", "d"]).maskPlan(environment: ["OFFSIDER_MASK_SECURE": "1"]).kinds == [.secure])
    }

    // MARK: - Batch

    private static func batch(_ steps: [String], on backend: FakeDeviceBackend, maskSecure: Bool = false) async throws -> [BatchStepRecord] {
        let context = BatchContext(
            backend: backend, device: device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200, maskSecure: maskSecure
        )
        let output = BatchOutput(json: true, write: { _ in }, writeError: { _ in })
        return try await Batch.runSteps(steps, context: context, session: backend.session, continueOnError: true, output: output, logger: OffsiderLogger())
    }

    @Test("batch screenshot steps reuse the cached tree for every tree mask")
    func batchReusesTree() async throws {
        let path = Self.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let backend = try Self.backend([
            SecureTextTests.passwordField(),
            FakeUI.node(.text, id: "profile-email", label: "e2e@example.com", frame: FakeUI.frame(16, 100, 200, 40)),
        ])

        let records = try await Self.batch(["assert --id password-field", "screenshot --mask-emails --output \(path)"], on: backend, maskSecure: true)
        let written = try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: path)))

        #expect(records.allSatisfy { $0.ok })
        #expect(records.last?.jsonLine().contains(#""maskedBy":{"secure":1,"emails":1}"#) == true)
        #expect(backend.treeReads == 1)
        #expect(Self.pixel(written, 600, 870) == Self.black)
        #expect(Self.point(written, 116, 120) == Self.black)
    }
}
