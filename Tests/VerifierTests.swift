import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import OffsiderAndroid
import OffsiderCore
@testable import Offsider

@MainActor
private final class FakeSimulator {
    var clock: TimeInterval = 0
    var trees: [UITree]
    var screens: [Data]
    var bands = ScreenBands(top: 60, bottom: 0)
    /// Gives the verifier a change wait, as a backend with accessibility events does.
    var waitsForChange = false
    private(set) var treeReads = 0
    private(set) var screenReads = 0
    private(set) var sleeps: [Duration] = []
    private(set) var waits: [Duration] = []

    init(trees: [UITree], screens: [Data] = []) {
        self.trees = trees
        self.screens = screens
    }

    var dependencies: Verifier.Dependencies {
        Verifier.Dependencies(
            tree: { [unowned self] in
                treeReads += 1
                clock += 0.3
                return trees.count > 1 ? trees.removeFirst() : trees[0]
            },
            screenshot: { [unowned self] in
                screenReads += 1
                guard !screens.isEmpty else { throw CLIError(errorDescription: "no screenshot") }
                return screens.count > 1 ? screens.removeFirst() : screens[0]
            },
            sleep: { [unowned self] duration in
                sleeps.append(duration)
                clock += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            },
            now: { [unowned self] in clock },
            bands: { [unowned self] in bands },
            waitForChange: waitsForChange ? { [unowned self] duration in
                waits.append(duration)
                clock += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            } : nil
        )
    }
}

private func tree(count: String, extra: [UINode] = []) -> UITree {
    FakeUI.tree(width: 64, height: 128, [FakeUI.node(.text, id: "tap-count", value: count)] + extra)
}

private let emptyTree = UITree(platform: .ios, device: "fake-device", roots: [FakeUI.node(.application)])

private func screen(shade: UInt8) -> Data {
    let width = 64, height = 128
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 64..<height {
        for x in 0..<width { bytes[(y * width + x) * 4] = shade }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// `screen(shade: 10)` except its bottom 16 rows, which sit inside a 48-point bottom band at this scale.
/// The `screen(shade: 10)` image with its rightmost 8 columns painted `shade`.
private func rightEdge(shade: UInt8) -> Data {
    let width = 64, height = 128
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            if x >= width - 8 { bytes[(y * width + x) * 4] = shade } else if y >= 64 { bytes[(y * width + x) * 4] = 10 }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func bottomBar(shade: UInt8) -> Data {
    let width = 64, height = 128
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 64..<height {
        for x in 0..<width { bytes[(y * width + x) * 4] = y >= height - 16 ? shade : 10 }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@MainActor
@Suite("Verifier Tests")
struct VerifierTests {
    private func run(
        _ fake: FakeSimulator,
        styles: [TapDeliveryStyle?] = [.simulator, .physical],
        timeout: Duration = .seconds(2),
        actions: inout [Verifier.Attempt],
        retries: inout [Int],
        onAction: (Int) throws -> Void = { _ in }
    ) async throws -> Verifier.Outcome {
        var recorded: [Verifier.Attempt] = []
        var retried: [Int] = []
        defer {
            actions = recorded
            retries = retried
        }
        return try await Verifier.run(
            styles: styles,
            timeout: timeout,
            dependencies: fake.dependencies,
            onRetry: { failed, _ in retried.append(failed.number) },
            action: { attempt in
                recorded.append(attempt)
                try onAction(attempt.number)
            }
        )
    }

    @Test("A settled tree change on the first attempt verifies without a retry")
    func treeChangeVerifies() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0"), tree(count: "0"), tree(count: "1")])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.change == .accessibilityTree)
        #expect(outcome.attempts == 1)
        #expect(outcome.style == .simulator)
        #expect(outcome.summary?.contains("tap-count") == true)
        #expect(outcome.changes == [VerifyChange(kind: .changed, node: "text id=tap-count", field: "value", old: "0", new: "1")])
        #expect(outcome.changesTruncated == 0 && outcome.note == nil)
        #expect(actions.count == 1)
        #expect(retries.isEmpty)
    }

    @Test("the resolver's tree stands in for the first read, so the verifier reads one tree fewer and sees the second before acting")
    func initialTreeSavesARead() async throws {
        func reads(initial: UITree?) async throws -> (Int, [String?]) {
            let fake = FakeSimulator(trees: (initial == nil ? [tree(count: "0")] : []) + [tree(count: "0"), tree(count: "1")])
            var seen: [String?] = []
            _ = try await Verifier.run(
                styles: [nil], timeout: .seconds(2), dependencies: fake.dependencies, initialTree: initial,
                beforeAction: { seen.append($0.roots[0].children[0].value) }, action: { _ in }
            )
            return (fake.treeReads, seen)
        }
        let without = try await reads(initial: nil)
        let with = try await reads(initial: tree(count: "0"))
        #expect(with.0 == without.0 - 1)
        #expect(with.1 == ["0"])
    }

    @Test("changes are empty when only the screenshot changed")
    func screenshotOnlyHasNoChanges() async throws {
        let fake = FakeSimulator(trees: [emptyTree], screens: [screen(shade: 10), screen(shade: 200)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil], timeout: .seconds(1), actions: &actions, retries: &retries)
        #expect(outcome.change == .screenshot)
        #expect(outcome.changes.isEmpty && outcome.changesTruncated == 0)
    }

    @Test("changes list value and state changes first, then added, removed and moved, capped at 10 with a truncated count")
    func changesOrderAndCap() {
        let rows = (0..<12).map { FakeUI.node(.text, id: "row-\($0)", value: "a", frame: FakeUI.frame(0, Double($0) * 44, 402, 44)) }
        let old = FakeUI.tree(rows + [
            FakeUI.node(.button, id: "gone", label: "Gone", frame: FakeUI.frame(0, 900, 100, 44)),
            FakeUI.node(.button, id: "mover", label: "Mover", frame: FakeUI.frame(0, 950, 100, 44)),
            FakeUI.node(.switch, id: "wifi", frame: FakeUI.frame(0, 1000, 60, 30), state: UIState(checked: false)),
        ])
        let new = FakeUI.tree([FakeUI.node(.button, id: "fresh", label: "Fresh", frame: FakeUI.frame(0, 850, 100, 44))]
            + rows.map { var row = $0; row.value = String(repeating: "b", count: 80); return row } + [
            FakeUI.node(.button, id: "mover", label: "Mover", frame: FakeUI.frame(0, 990, 100, 44)),
            FakeUI.node(.switch, id: "wifi", frame: FakeUI.frame(0, 1000, 60, 30), state: UIState(checked: true)),
        ])
        let capped = TreeDiff.diff(old: old, new: new, filter: Verifier.changeFilter).cappedChanges()

        #expect(capped.changes.count == 10)
        #expect(capped.truncated == 6)
        #expect(capped.changes.allSatisfy { $0.kind == .changed && ($0.field == "value" || $0.field == "checked") })
        #expect(capped.changes[0] == VerifyChange(kind: .changed, node: "text id=row-0", field: "value", old: "a", new: String(repeating: "b", count: 59) + "…"))
        let all = TreeDiff.diff(old: old, new: new, filter: Verifier.changeFilter).cappedChanges(limit: 100).changes
        #expect(all.suffix(3).map(\.kind) == [.added, .removed, .changed])
        #expect(all.last == VerifyChange(kind: .changed, node: #"button "Mover" id=mover"#, field: "frame", old: "(0, 950) 100x44", new: "(0, 990) 100x44"))
        #expect(all.contains(VerifyChange(kind: .changed, node: "switch id=wifi", field: "checked", old: "false", new: "true")))
    }

    private static func keyboardScreen(keyboard: Bool, fieldY: Double = 300, extra: [UINode] = []) -> UITree {
        var children = [FakeUI.node(.textField, id: "name", label: "Name", value: "Ada", frame: FakeUI.frame(16, fieldY, 370, 44))] + extra
        if keyboard {
            children.append(FakeUI.node(.keyboard, label: "Keyboard", frame: FakeUI.frame(0, 500, 402, 374), children: [
                FakeUI.node(.button, label: "return", frame: FakeUI.frame(300, 800, 100, 44)),
            ]))
        }
        return FakeUI.tree(children)
    }

    @Test("keyboard_closed is noted when only the keyboard left, frame moves aside")
    func keyboardClosedNoted() {
        let outcome = Verifier.Outcome(verified: true, attempts: 1, change: .accessibilityTree, style: nil, summary: nil)
            .listing(from: Self.keyboardScreen(keyboard: true), to: Self.keyboardScreen(keyboard: false, fieldY: 340), skipping: [])
        #expect(outcome.note == .keyboardClosed)
        #expect(outcome.changes.contains { $0.kind == .removed })
    }

    @Test("keyboard_closed is not noted when another node changed, or when the read was truncated")
    func keyboardClosedNotNoted() {
        let base = Verifier.Outcome(verified: true, attempts: 1, change: .accessibilityTree, style: nil, summary: nil)
        let other = base.listing(
            from: Self.keyboardScreen(keyboard: true),
            to: Self.keyboardScreen(keyboard: false, extra: [FakeUI.node(.text, id: "saved", label: "Saved", frame: FakeUI.frame(16, 400, 100, 20))]),
            skipping: []
        )
        #expect(other.note == nil)
        var truncated = Self.keyboardScreen(keyboard: false)
        truncated.sourceTruncated = true
        #expect(base.listing(from: Self.keyboardScreen(keyboard: true), to: truncated, skipping: []).note == nil)
    }

    @Test("secure values appear masked in changes")
    func secureMaskedInChanges() {
        func screen(_ value: String) -> UITree {
            FakeUI.tree([FakeUI.node(.secureTextField, id: "password", label: "Password", value: SecureText.masked(value), frame: FakeUI.frame(16, 300, 370, 44))])
        }
        let changes = TreeDiff.diff(old: screen("abc"), new: screen("abcd"), filter: Verifier.changeFilter).cappedChanges().changes
        #expect(changes == [VerifyChange(kind: .changed, node: #"secureTextField "Password" id=password"#, field: "value", old: "•••", new: "••••")])
    }

    @Test("With a change wait, polls after the action wait on it, while the gap between the baseline reads stays a sleep")
    func changeWaitReplacesPollSleeps() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0"), tree(count: "0"), tree(count: "1")])
        fake.waitsForChange = true
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(fake.sleeps == [.milliseconds(200)])
        #expect(fake.waits == [.milliseconds(200), .milliseconds(200)])
    }

    @Test("Without a change wait, every poll sleeps the interval")
    func pollsSleepWithoutChangeWait() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0"), tree(count: "0"), tree(count: "1")])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        _ = try await run(fake, actions: &actions, retries: &retries)

        #expect(fake.sleeps == [.milliseconds(200), .milliseconds(200), .milliseconds(200)])
        #expect(fake.waits.isEmpty)
    }

    @Test("An unchanged tree with a changed screen verifies by screenshot")
    func screenshotFallback() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0")], screens: [screen(shade: 10), screen(shade: 200)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.change == .screenshot)
        #expect(actions.count == 1)
    }

    @Test("Nothing changing runs every attempt with alternating styles and is unverified")
    func nothingChanges() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0")], screens: [screen(shade: 10)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(
            fake,
            styles: [.simulator, .physical, .simulator],
            actions: &actions,
            retries: &retries
        )

        #expect(!outcome.verified)
        #expect(outcome.change == ChangeKind.none)
        #expect(outcome.attempts == 3)
        #expect(actions.map(\.style) == [.simulator, .physical, .simulator])
        #expect(retries == [1, 2])
    }

    @Test("An action that throws propagates without another attempt")
    func actionErrorPropagates() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0")])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        await #expect(throws: CLIError.self) {
            _ = try await run(fake, actions: &actions, retries: &retries) { _ in
                throw CLIError(errorDescription: "HID send failed")
            }
        }
        #expect(actions.count == 1)
        #expect(retries.isEmpty)
    }

    @Test("Unknown reads after dispatch keep polling until a real change")
    func unknownThenChange() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0"), tree(count: "0"), emptyTree, emptyTree, tree(count: "1")])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.change == .accessibilityTree)
        #expect(actions.count == 1)
    }

    @Test("An element that already changes between baseline reads does not count")
    func volatileBaselineIgnored() async throws {
        func spinner(_ value: String) -> UITree {
            tree(count: "0", extra: [FakeUI.node(.progress, id: "spinner", value: value)])
        }
        var sequence = [spinner("1"), spinner("2")]
        for index in 0..<40 { sequence.append(spinner(String(index + 3))) }
        let fake = FakeSimulator(trees: sequence, screens: [screen(shade: 10)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil], actions: &actions, retries: &retries)

        #expect(!outcome.verified)
        #expect(outcome.change == ChangeKind.none)
    }

    @Test("A change that never settles before the deadline still verifies")
    func unsettledChangeVerifies() async throws {
        var sequence = [tree(count: "0"), tree(count: "0")]
        for index in 0..<40 { sequence.append(tree(count: String(index + 1))) }
        let fake = FakeSimulator(trees: sequence)
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, timeout: .seconds(1), actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.change == .accessibilityTree)
        #expect(outcome.attempts == 1)
        #expect(fake.clock < 5)
    }

    @Test("An unknown baseline goes straight to the screenshot check")
    func unknownBaselineUsesScreenshot() async throws {
        let fake = FakeSimulator(trees: [emptyTree], screens: [screen(shade: 10), screen(shade: 200)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil], actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.change == .screenshot)
        #expect(fake.treeReads == 2)
    }

    @Test("The bands are scaled to pixels and excluded only in portrait")
    func bandsOnlyInPortrait() {
        let png = screen(shade: 10)
        let portrait = AccessibilitySnapshot.Frame(x: 0, y: 0, width: 32, height: 64)
        let landscape = AccessibilitySnapshot.Frame(x: 0, y: 0, width: 64, height: 32)
        let android = ScreenBands(top: 60, bottom: 48)
        #expect(Verifier.bandPixels(pngData: png, screenFrame: portrait, bands: android) == (120, 96, 0, 0))
        #expect(Verifier.bandPixels(pngData: png, screenFrame: portrait, bands: ScreenBands(top: 60, bottom: 0)) == (120, 0, 0, 0))
        #expect(Verifier.bandPixels(pngData: png, screenFrame: landscape, bands: android) == (0, 0, 0, 0))
        #expect(Verifier.bandPixels(pngData: png, screenFrame: nil, bands: android) == (0, 0, 0, 0))
    }

    @Test("A physical device's status bar band follows the UI's top edge onto the raw screenshot in every orientation", arguments: [
        (0, 124, 0, 0, 0), (1, 0, 0, 0, 124), (2, 0, 124, 0, 0), (3, 0, 0, 124, 0),
    ])
    func deviceBandsInLandscape(turns: Int, top: Int, bottom: Int, left: Int, right: Int) {
        let png = screen(shade: 10)
        let landscape = AccessibilitySnapshot.Frame(x: 0, y: 0, width: 64, height: 32)
        let device = ScreenBands(top: 62, bottom: 0, everyOrientation: true, screenshotQuarterTurns: turns)
        #expect(Verifier.bandPixels(pngData: png, screenFrame: landscape, bands: device) == (top, bottom, left, right))
    }

    @Test("Pixels in excluded side columns never count as a change")
    func sideColumnsExcluded() throws {
        let before = try #require(ImageFingerprint(pngData: screen(shade: 10), excludingRightPixels: 8))
        let changedRight = try #require(ImageFingerprint(pngData: rightEdge(shade: 200), excludingRightPixels: 8))
        #expect(!ScreenChange.detect(before: before, after: [changedRight]))
        #expect(before.comparedTileCount == 14 * 32)
        let unmasked = try #require(ImageFingerprint(pngData: rightEdge(shade: 200)))
        #expect(ScreenChange.detect(before: try #require(ImageFingerprint(pngData: screen(shade: 10))), after: [unmasked]))
    }

    @Test("A screen change only in the bottom band verifies with no bottom band and not with one")
    func bottomBandChange() async throws {
        for (bands, verified) in [(ScreenBands(top: 60, bottom: 0), true), (ScreenBands(top: 60, bottom: 48), false)] {
            let fake = FakeSimulator(trees: [tree(count: "0")], screens: [screen(shade: 10), bottomBar(shade: 200)])
            fake.bands = bands
            var actions: [Verifier.Attempt] = []
            var retries: [Int] = []
            let outcome = try await run(fake, styles: [nil], timeout: .seconds(1), actions: &actions, retries: &retries)
            #expect(outcome.verified == verified, "bands \(bands)")
        }
    }

    @Test("An unverified command points at doctor only for iOS simulators, which doctor checks")
    func unverifiedHintByPlatform() throws {
        let outcome = Verifier.Outcome(verified: false, attempts: 1, change: .none, style: nil, summary: nil)
        let options = try VerificationOptions.parse(["--verify"])
        func line(_ device: DeviceID) -> String {
            let request = VerifyRequest(
                command: "key", subject: "Key 4", target: "4", backend: StubBackend(session: RecordingInputSession()),
                device: device, options: options, styles: [nil]
            )
            return VerifyOutput.unverifiedLine(outcome, for: request)
        }
        let udid = UUID().uuidString
        #expect(line(DeviceID(rawValue: udid, platform: .ios)).hasSuffix("Check the target with describe-ui, or run offsider doctor --device \(udid)."))
        #expect(line(DeviceID(rawValue: "emulator-5556", platform: .android)).hasSuffix("Check the target with describe-ui."))
    }

    @Test("The backends' bands: iOS keeps the status bar only; Android with no helper running keeps 60 and 48 dp")
    func backendBands() async {
        let device = DeviceID(rawValue: UUID().uuidString, platform: .ios)
        #expect(await IOSBackend(logger: OffsiderLogger()).volatileScreenBands(for: device) == ScreenBands(top: 60, bottom: 0))
        let android = AndroidBackend(host: .live(environment: [:])) { _, _ in }
        #expect(await android.volatileScreenBands(for: DeviceID(rawValue: "emulator-5556", platform: .android)) == ScreenBands(top: 60, bottom: 48))
    }
}
