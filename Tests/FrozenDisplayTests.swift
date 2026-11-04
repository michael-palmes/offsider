import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Frozen display", .serialized)
@MainActor
struct FrozenDisplayTests {
    static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)

    static func tree(_ label: String) -> UITree {
        FakeUI.tree([FakeUI.node(.button, label: label, frame: FakeUI.frame(20, 100, 200, 44))])
    }

    /// The notices `screenshot` gives for each tree in turn, all over the same picture unless `images` says otherwise.
    static func warnings(trees: [UITree], images: [Data]? = nil, screen: UIScreenInfo? = nil, device: DeviceID = simulator, cacheOn: Bool = true) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frozen-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let same = try ScreenImage.encode(TestImages.make(width: 30, height: 60), as: .png)
        let environment = TreeCacheEnvironment(directory: { directory }, cacheOn: cacheOn, now: { Date() }, sleep: { _ in })
        let capture = ConsoleCapture()
        await TreeCacheEnvironment.$current.withValue(environment) {
            await Console.$current.withValue(capture.console(out: .agent, err: .agent)) {
                for (index, tree) in trees.enumerated() {
                    let png = images?[index] ?? same
                    FrozenDisplay.check(try! ScreenCapture.make(png: png, platform: device.platform, screen: screen), tree: tree, device: device)
                }
            }
        }
        if !cacheOn { #expect(try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty) }
        return capture.err
    }

    @Test("the same picture over a changed tree warns, naming lock, then Home twice")
    func frozen() async throws {
        let err = try await Self.warnings(trees: [Self.tree("Log in"), Self.tree("Home")])
        #expect(err.contains("This screenshot matches the last one, though the elements on screen changed"))
        #expect(err.contains("offsider button lock --device \(Self.simulator.rawValue)"))
        #expect(err.contains("offsider button home --device \(Self.simulator.rawValue)` twice"))
    }

    @Test("a still screen, a new picture and the first capture stay quiet")
    func quiet() async throws {
        #expect(try await Self.warnings(trees: [Self.tree("Log in")]).isEmpty)
        #expect(try await Self.warnings(trees: [Self.tree("Log in"), Self.tree("Log in")]).isEmpty)
        let other = try ScreenImage.encode(TestImages.make(width: 30, height: 60, marked: [(5, 5)]), as: .png)
        let first = try ScreenImage.encode(TestImages.make(width: 30, height: 60), as: .png)
        #expect(try await Self.warnings(trees: [Self.tree("Log in"), Self.tree("Home")], images: [first, other]).isEmpty)
    }

    /// A 402 x 874 point screen at one pixel a point, marked at each point given.
    static func screenPicture(marked: [(x: Int, y: Int)] = []) throws -> Data {
        try ScreenImage.encode(TestImages.make(width: 402, height: 874, marked: marked), as: .png)
    }

    static let screen = UIScreenInfo(width: 402, height: 874, captureArrivesUpright: true)

    @Test("a frozen display whose status bar clock and bottom edge still change warns, and a change between them stays quiet")
    func bandsLeftOut() async throws {
        let moved = try Self.screenPicture(marked: [(30, 20), (200, 860)])
        let err = try await Self.warnings(trees: [Self.tree("Log in"), Self.tree("Home")], images: [try Self.screenPicture(), moved], screen: Self.screen)
        #expect(err.contains("This screenshot matches the last one, though the elements on screen changed"))

        let changed = try Self.screenPicture(marked: [(200, 400)])
        #expect(try await Self.warnings(trees: [Self.tree("Log in"), Self.tree("Home")], images: [try Self.screenPicture(), changed], screen: Self.screen).isEmpty)
    }

    @Test("an element wholly in the status bar or bottom edge is no tree change, as the picture leaves those rows out")
    func bandElementsLeftOut() {
        let plain = FakeUI.tree([FakeUI.node(.button, label: "Log in", frame: FakeUI.frame(20, 100, 200, 44))])
        let clock = FakeUI.tree([
            FakeUI.node(.button, label: "Log in", frame: FakeUI.frame(20, 100, 200, 44)),
            FakeUI.node(.text, label: "9:41", frame: FakeUI.frame(30, 14, 40, 20)),
            FakeUI.node(.other, label: "Home indicator", frame: FakeUI.frame(130, 850, 140, 8)),
        ])
        #expect(FrozenDisplayRecord.digest(tree: plain, leavingOut: FrozenDisplay.bands) == FrozenDisplayRecord.digest(tree: clock, leavingOut: FrozenDisplay.bands))
        #expect(FrozenDisplayRecord.digest(tree: plain) != FrozenDisplayRecord.digest(tree: clock))
    }

    @Test("an emulator is never checked")
    func onlySimulators() async throws {
        let emulator = DeviceID(rawValue: "emulator-5554", platform: .android)
        #expect(try await Self.warnings(trees: [Self.tree("Log in"), Self.tree("Home")], device: emulator).isEmpty)
    }

    @Test("with the tree cache off no digest is kept, so nothing warns")
    func cacheOff() async throws {
        #expect(try await Self.warnings(trees: [Self.tree("Log in"), Self.tree("Home")], cacheOn: false).isEmpty)
    }

    @Test("the record holds digests only, so no label reaches the disk, and a value change alone is no tree change")
    func digestsOnly() throws {
        let record = FrozenDisplayRecord(image: FrozenDisplayRecord.digest(pixels: Data([1])), tree: FrozenDisplayRecord.digest(tree: Self.tree("Secret label")))
        #expect(!String(decoding: record.encoded(), as: UTF8.self).contains("Secret"))
        #expect(FrozenDisplayRecord(data: record.encoded()) == record)
        #expect(FrozenDisplayRecord.digest(tree: FakeUI.tree([FakeUI.node(.textField, label: "Name", value: "a", frame: FakeUI.frame(1, 1, 9, 9))]))
            == FrozenDisplayRecord.digest(tree: FakeUI.tree([FakeUI.node(.textField, label: "Name", value: "b", frame: FakeUI.frame(1, 1, 9, 9))])))
    }
}
