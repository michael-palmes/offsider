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
    /// The device's cached tree, dated against `LiveTextTests.now`.
    var cached: TreeCacheRecord?
    /// Each read and capture yields once, as device I/O does, so work started alongside it can run.
    var yields = false
    private(set) var events: [String] = []
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
                events.append("tree")
                if yields { await Task.yield() }
                clock += 0.3
                return trees.count > 1 ? trees.removeFirst() : trees[0]
            },
            screenshot: { [unowned self] in
                screenReads += 1
                events.append("shot-start")
                if yields { for _ in 0..<5 { await Task.yield() } }
                events.append("shot-end")
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
            } : nil,
            cachedRecord: { [unowned self] in cached },
            date: { LiveTextTests.now }
        )
    }

    func record(_ event: String) {
        events.append(event)
    }
}

private func tree(count: String, extra: [UINode] = []) -> UITree {
    FakeUI.tree(width: 64, height: 128, [FakeUI.node(.text, id: "tap-count", value: count)] + extra)
}

private let emptyTree = UITree(platform: .ios, device: "fake-device", roots: [FakeUI.node(.application)])

/// With `caret`, a 2 by 6 pixel bar that covers two tiles; with `label`, a 12 by 8 pixel block of that shade that covers six, as a countdown's text does.
private func screen(shade: UInt8, caret: Bool = false, label: UInt8? = nil) -> Data {
    let width = 64, height = 128
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 64..<height {
        for x in 0..<width {
            var red = caret && (10..<12).contains(x) && (70..<76).contains(y) ? 0 : shade
            if let label, (8..<20).contains(x), (80..<88).contains(y) { red = label }
            bytes[(y * width + x) * 4] = red
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
        let fake = FakeSimulator(trees: [emptyTree], screens: [screen(shade: 10), screen(shade: 10), screen(shade: 200)])
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
        let fake = FakeSimulator(trees: [tree(count: "0")], screens: [screen(shade: 10), screen(shade: 10), screen(shade: 200)])
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
        let fake = FakeSimulator(trees: [emptyTree], screens: [screen(shade: 10), screen(shade: 10), screen(shade: 200)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil], actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.change == .screenshot)
        #expect(fake.treeReads == 2)
    }

    @Test("With no tree, after-shots continue while a transition is still moving, so a change that settles verifies without a second action")
    func transitionSettlesBeforeComparing() async throws {
        let fake = FakeSimulator(trees: [emptyTree], screens: [screen(shade: 10), screen(shade: 10), screen(shade: 60), screen(shade: 120), screen(shade: 200)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil, nil], actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.change == .screenshot)
        #expect(actions.count == 1)
        #expect(fake.screenReads == 7)
    }

    @Test("A screen that never settles stops the after-shots at their cap, or after one extra once the attempt's time is up", arguments: [
        (2000, 2 + Verifier.maxScreenshots), (500, 2 + Verifier.screenshotCount + 1),
    ])
    func endlessMotionIsCapped(timeoutMilliseconds: Int, reads: Int) async throws {
        let shades: [UInt8] = [10, 40, 80, 120, 160, 200, 240, 20, 60, 100, 140]
        let fake = FakeSimulator(trees: [emptyTree], screens: shades.map { screen(shade: $0) })
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        _ = try await run(fake, styles: [nil], timeout: .milliseconds(timeoutMilliseconds), actions: &actions, retries: &retries)

        #expect(fake.screenReads == reads)
    }

    /// A screen whose bottom half changes on every capture, as a playing video does.
    private static let endlessMotion = (0..<20).map { screen(shade: UInt8(10 + $0 * 12)) }

    @Test("Without a tree, an input that starts endless motion verifies on its first attempt and is sent once")
    func motionStartedByInputVerifies() async throws {
        let fake = FakeSimulator(trees: [emptyTree], screens: [screen(shade: 10)] + Self.endlessMotion)
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil, nil], actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.change == .screenshot)
        #expect(outcome.attempts == 1)
        #expect(actions.count == 1)
        #expect(retries.isEmpty)
    }

    @Test("With a tree that never changes, motion the input starts reads as no change, so the input is retried and unverified")
    func motionStartedUnderUnchangedTreeIsNotCounted() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0")], screens: [screen(shade: 10)] + Self.endlessMotion)
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil, nil], actions: &actions, retries: &retries)

        #expect(!outcome.verified)
        #expect(outcome.change == ChangeKind.none)
        #expect(actions.count == 2)
    }

    @Test("Before the input, a tree needs one screenshot and no tree two", arguments: [(true, 1), (false, 2)])
    func beforeShotsFollowTheTree(knownTree: Bool, shots: Int) async throws {
        let fake = FakeSimulator(trees: [knownTree ? tree(count: "0") : emptyTree], screens: [screen(shade: 10)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        var shotsBeforeInput: Int?
        _ = try await run(fake, styles: [nil], timeout: .seconds(1), actions: &actions, retries: &retries) { _ in
            shotsBeforeInput = fake.screenReads
        }

        #expect(shotsBeforeInput == shots)
    }

    @Test("An input that changes nothing on a screen already moving does not verify")
    func motionAlreadyRunningDoesNotVerify() async throws {
        let fake = FakeSimulator(trees: [emptyTree], screens: Self.endlessMotion)
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil, nil], actions: &actions, retries: &retries)

        #expect(!outcome.verified)
        #expect(outcome.change == ChangeKind.none)
        #expect(actions.count == 2)
    }

    @Test("An input that stops motion verifies on its first attempt")
    func motionStoppedByInputVerifies() async throws {
        let fake = FakeSimulator(trees: [emptyTree], screens: [screen(shade: 10), screen(shade: 40), screen(shade: 200)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil, nil], actions: &actions, retries: &retries)

        #expect(outcome.verified)
        #expect(outcome.attempts == 1)
    }

    @Test("Without a tree, a caret that both before-shots catch in one phase and that blinks after the input does not verify")
    func caretBlinkingAfterStillBeforeDoesNotVerify() async throws {
        let on = screen(shade: 10, caret: true)
        let off = screen(shade: 10)
        let fake = FakeSimulator(trees: [emptyTree], screens: [on, on, off, on, off])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil], timeout: .seconds(1), actions: &actions, retries: &retries)

        #expect(!outcome.verified)
    }

    @Test("Without a tree, an input that changes nothing does not verify when a countdown label ticks between the after-shots")
    func countdownTickDoesNotVerify() async throws {
        let before = screen(shade: 10, label: 60)
        let fake = FakeSimulator(trees: [emptyTree], screens: [before, before, before, screen(shade: 10, label: 90)])
        var actions: [Verifier.Attempt] = []
        var retries: [Int] = []
        let outcome = try await run(fake, styles: [nil], timeout: .seconds(1), actions: &actions, retries: &retries)

        #expect(!outcome.verified)
        #expect(outcome.change == ChangeKind.none)
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
        #expect(!ScreenChange.detect(before: [before], after: [changedRight]))
        #expect(before.comparedTileCount == 14 * 32)
        let unmasked = try #require(ImageFingerprint(pngData: rightEdge(shade: 200)))
        #expect(ScreenChange.detect(before: [try #require(ImageFingerprint(pngData: screen(shade: 10)))], after: [unmasked]))
    }

    @Test("A screen change only in the bottom band verifies with no bottom band and not with one")
    func bottomBandChange() async throws {
        for (bands, verified) in [(ScreenBands(top: 60, bottom: 0), true), (ScreenBands(top: 60, bottom: 48), false)] {
            let fake = FakeSimulator(trees: [tree(count: "0")], screens: [screen(shade: 10), screen(shade: 10), bottomBar(shade: 200)])
            fake.bands = bands
            var actions: [Verifier.Attempt] = []
            var retries: [Int] = []
            let outcome = try await run(fake, styles: [nil], timeout: .seconds(1), actions: &actions, retries: &retries)
            #expect(outcome.verified == verified, "bands \(bands)")
        }
    }

    @Test("With a noise tolerance, a screen whose colours drift a few units does not verify and a real change does")
    func noiseToleranceVerifies() async throws {
        for (after, tolerance, verified) in [(screen(shade: 13), 6, false), (screen(shade: 13), 0, true), (screen(shade: 200), 6, true)] {
            let fake = FakeSimulator(trees: [tree(count: "0")], screens: [screen(shade: 10), screen(shade: 10), after])
            fake.bands = ScreenBands(top: 60, bottom: 0, noiseTolerance: tolerance)
            var actions: [Verifier.Attempt] = []
            var retries: [Int] = []
            let outcome = try await run(fake, styles: [nil], timeout: .seconds(1), actions: &actions, retries: &retries)
            #expect(outcome.verified == verified, "tolerance \(tolerance)")
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


@MainActor
@Suite("Verifier --verify-id and --verify-ignore-text")
struct VerifierModeTests {
    private static func page(_ ids: [String], clock: String = "1") -> UITree {
        FakeUI.tree(width: 64, height: 128, [FakeUI.node(.text, id: "clock", label: clock)] + ids.map { FakeUI.node(.button, id: $0, label: $0, frame: FakeUI.frame(0, 10, 60, 20)) })
    }

    @Test("an element that appears 3 s after the input verifies within a 10 s timeout, with no screenshot read")
    func slowAppearVerifies() async throws {
        let fake = FakeSimulator(trees: Array(repeating: Self.page(["next"]), count: 11) + [Self.page(["page-2"])], screens: [screen(shade: 10)])
        var sent = 0
        let outcome = try await Verifier.run(styles: [nil], timeout: .seconds(10), dependencies: fake.dependencies, mode: .appearing(id: "page-2")) { _ in sent += 1 }

        #expect(sent == 1)
        #expect(outcome.verified && outcome.change == .element)
        #expect(fake.screenReads == 0)
        #expect(fake.clock >= 3 && fake.clock <= 10)
    }

    @Test("an element already on screen before the input is refused before anything is sent")
    func presentAtBaselineRefused() async throws {
        let fake = FakeSimulator(trees: [Self.page(["page-2"])])
        var sent = 0
        let error = await #expect(throws: CLIError.self) {
            try await Verifier.run(styles: [nil], timeout: .seconds(10), dependencies: fake.dependencies, mode: .appearing(id: "page-2")) { _ in sent += 1 }
        }
        #expect(error?.reason == .verifyTargetPresent)
        #expect(sent == 0)
    }

    @Test("an element that never appears is unverified, and the screen is never compared")
    func neverAppears() async throws {
        let fake = FakeSimulator(trees: [Self.page(["next"])], screens: [screen(shade: 10), screen(shade: 200)])
        let outcome = try await Verifier.run(styles: [nil], timeout: .seconds(2), dependencies: fake.dependencies, mode: .appearing(id: "page-2")) { _ in }
        #expect(!outcome.verified && outcome.change == .none)
        #expect(fake.screenReads == 0)
    }

    @Test("ignoring text, a screen whose only change is a ticking label is unverified, even when its pixels change")
    func ignoreTextTickIsUnverified() async throws {
        var ticks = 0
        let trees = (0..<40).map { _ -> UITree in ticks += 1; return Self.page(["next"], clock: String(ticks)) }
        let fake = FakeSimulator(trees: trees, screens: [screen(shade: 10), screen(shade: 200)])
        let outcome = try await Verifier.run(styles: [nil], timeout: .seconds(2), dependencies: fake.dependencies, mode: .change(ignoringText: true)) { _ in }
        #expect(!outcome.verified)
        #expect(fake.screenReads == 0)
    }

    @Test("--verify-id defaults to no retries and a 10 s timeout, and conflicts with --verify-ignore-text")
    func options() throws {
        let appearing = try VerificationOptions.parse(["--verify-id", "page-2"])
        #expect(appearing.verify && appearing.resolvedRetries == 0 && appearing.resolvedTimeout == 10)
        #expect(appearing.mode == .appearing(id: "page-2"))
        #expect(try VerificationOptions.parse(["--verify-ignore-text"]).mode == .change(ignoringText: true))
        #expect(try VerificationOptions.parse(["--verify-id", "a", "--retries", "2"]).resolvedRetries == 2)
        #expect(throws: (any Error).self) { try VerificationOptions.parse(["--verify-id", "a", "--verify-ignore-text"]) }
    }
}

@MainActor
@Suite("Verifier live values, LogBox and phases")
struct VerifierLiveTests {
    private static let toggle = "live-ticker-toggle"

    private static func ticking(tick: Int, alerts: Bool = false, extra: [UINode] = []) -> UITree {
        FakeUI.tree([
            FakeUI.node(.text, id: "live-ticker-heart-rate", label: "\(72 + tick) bpm", frame: FakeUI.frame(16, 100, 370, 40)),
            FakeUI.node(.switch, id: toggle, label: "Goal Alerts", frame: FakeUI.frame(16, 200, 52, 32), state: UIState(checked: alerts)),
            FakeUI.node(.button, id: "live-ticker-noop", label: "Do Nothing", frame: FakeUI.frame(16, 260, 180, 44)),
        ] + extra)
    }

    private static func run(_ fake: FakeSimulator, styles: [TapDeliveryStyle?] = [.simulator, .physical], target: UINode? = nil) async throws -> (Verifier.Outcome, Int) {
        var sent = 0
        let outcome = try await Verifier.run(styles: styles, timeout: .seconds(1), dependencies: fake.dependencies, target: target) { _ in sent += 1 }
        return (outcome, sent)
    }

    @Test("a ticker learnt from the cache is not taken for the input's effect, the input is not retried, and the heart rate is named as ignored")
    func cachedTickerIsIgnored() async throws {
        // The heart rate ticks every other read, so the two reads before the input agree.
        let ticks = (0..<40).map { Self.ticking(tick: 1 + $0 / 2) }
        let fake = FakeSimulator(trees: ticks)
        fake.cached = try LiveTextTests.record(Self.ticking(tick: 0))
        let (outcome, sent) = try await Self.run(fake)
        #expect(!outcome.verified && outcome.change == ChangeKind.none)
        #expect(sent == 1)
        #expect(outcome.ignored.contains(VerifyIgnored(node: "live-ticker-heart-rate", reason: .live)))

        let unlearnt = FakeSimulator(trees: ticks)
        #expect(try await Self.run(unlearnt).0.verified, "without the cache the first tick reads as the input's effect")
    }

    @Test("a real change on a ticking screen verifies on the first attempt, and its change list leaves the ticker out")
    func realChangeOnTickingScreen() async throws {
        let fake = FakeSimulator(trees: [Self.ticking(tick: 1), Self.ticking(tick: 1), Self.ticking(tick: 2, alerts: true), Self.ticking(tick: 3, alerts: true)])
        fake.cached = try LiveTextTests.record(Self.ticking(tick: 0))
        let (outcome, sent) = try await Self.run(fake)
        #expect(outcome.verified && outcome.attempts == 1 && sent == 1)
        #expect(outcome.changes == [VerifyChange(kind: .changed, node: #"switch "Goal Alerts" id=live-ticker-toggle"#, field: "checked", old: "false", new: "true")])
    }

    @Test("a LogBox toast's count going up is no change, and the input is still retried")
    func toastCountIgnored() async throws {
        func toast(_ count: String) -> UINode {
            FakeUI.node(.other, label: "\(count), OffsiderFixture warning toast", frame: FakeUI.frame(10, 806, 382, 48))
        }
        let fake = FakeSimulator(trees: [Self.ticking(tick: 1, extra: [toast("!")]), Self.ticking(tick: 1, extra: [toast("!")]), Self.ticking(tick: 1, extra: [toast("2")])])
        let (outcome, sent) = try await Self.run(fake)
        #expect(!outcome.verified)
        #expect(sent == 2)
        #expect(outcome.ignored == [VerifyIgnored(node: "LogBox toast", reason: .toast)])
    }

    private static func spinning(_ step: Int, alerts: Bool = false) -> UITree {
        FakeUI.tree([
            FakeUI.node(.other, id: "spinner", label: "Loading", frame: FakeUI.frame(Double(16 + step), 400, 40, 40)),
            FakeUI.node(.switch, id: toggle, label: "Goal Alerts", frame: FakeUI.frame(16, 200, 52, 32), state: UIState(checked: alerts)),
        ])
    }

    @Test("a dropped first input on a screen with a spinner already moving is sent again, and the second takes effect")
    func volatileScreenRetries() async throws {
        let fake = FakeSimulator(trees: (0..<40).map { Self.spinning($0) })
        var sent = 0
        let outcome = try await Verifier.run(styles: [.simulator, .physical], timeout: .seconds(1), dependencies: fake.dependencies) { attempt in
            sent += 1
            if attempt.number == 2 { fake.trees = (100..<140).map { Self.spinning($0, alerts: true) } }
        }

        #expect(outcome.verified && outcome.attempts == 2 && sent == 2)
        #expect(outcome.ignored.contains(VerifyIgnored(node: "spinner", reason: .volatile)))
    }

    @Test("the LogBox inspector opening fails at once with logbox_opened, unless the input aimed at a toast")
    func inspectorFailsFast() async throws {
        let toast = FakeUI.node(.other, label: "!, OffsiderFixture error toast", frame: FakeUI.frame(10, 806, 382, 48))
        let inspector = FakeUI.node(.text, label: "Log 1 of 1", frame: FakeUI.frame(0, 60, 402, 30))
        let trees = [Self.ticking(tick: 1, extra: [toast]), Self.ticking(tick: 1, extra: [toast]), Self.ticking(tick: 1, extra: [inspector])]
        let fake = FakeSimulator(trees: trees)
        let (outcome, sent) = try await Self.run(fake)
        #expect(!outcome.verified && outcome.note == .logBoxOpened)
        #expect(sent == 1 && fake.treeReads == 3)

        let aimed = try await Self.run(FakeSimulator(trees: trees), target: toast)
        #expect(aimed.0.verified)
    }

    @Test("pixels under live text are left out of the screenshot check; a change elsewhere still verifies")
    func liveTilesExcluded() async throws {
        func small(_ heartRate: String) -> UITree {
            FakeUI.tree(width: 64, height: 128, [
                FakeUI.node(.text, id: "heart-rate", label: heartRate, frame: FakeUI.frame(8, 80, 12, 8)),
                FakeUI.node(.button, id: "noop", label: "Do Nothing", frame: FakeUI.frame(30, 100, 30, 10)),
            ])
        }
        let ticks = (0..<40).map { small("\($0 / 2 + 61) bpm") }
        for (after, verified) in [(screen(shade: 10, label: 90), false), (screen(shade: 200, label: 90), true)] {
            let fake = FakeSimulator(trees: ticks, screens: [screen(shade: 10, label: 60), after])
            fake.cached = try LiveTextTests.record(small("60 bpm"))
            let (outcome, _) = try await Self.run(fake, styles: [nil])
            #expect(outcome.verified == verified)
            #expect(outcome.change == (verified ? .screenshot : ChangeKind.none))
        }
    }

    @Test("the baseline capture runs alongside the second read, and the input waits for both")
    func captureRunsAlongsideRead() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0"), tree(count: "0"), tree(count: "1")], screens: [screen(shade: 10)])
        fake.yields = true
        _ = try await Verifier.run(styles: [nil], timeout: .seconds(1), dependencies: fake.dependencies) { _ in fake.record("action") }
        let events = fake.events
        let secondRead = try #require(events.indices.filter { events[$0] == "tree" }.dropFirst().first)
        let start = try #require(events.firstIndex(of: "shot-start"))
        let end = try #require(events.firstIndex(of: "shot-end"))
        let action = try #require(events.firstIndex(of: "action"))
        #expect(start < action && end < action && secondRead < action)
        #expect(events.prefix(action).filter { $0 == "tree" }.count == 2)
        #expect(start <= secondRead + 1, "the capture starts before the second read returns")
    }

    @Test("a switch target takes no baseline capture")
    func switchSkipsCapture() async throws {
        let fake = FakeSimulator(trees: [Self.ticking(tick: 1), Self.ticking(tick: 1), Self.ticking(tick: 1, alerts: true)], screens: [screen(shade: 10)])
        let target = Self.ticking(tick: 1).roots[0].children[1]
        let (outcome, _) = try await Self.run(fake, target: target)
        #expect(outcome.verified)
        #expect(fake.screenReads == 0)
    }

    @Test("a change that lands after the poll and the screenshot check verifies on the same attempt, from one more read")
    func lateChangeVerifiesBeforeRetry() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0"), tree(count: "0"), tree(count: "0"), tree(count: "0"), tree(count: "1")], screens: [screen(shade: 10)])
        let (outcome, sent) = try await Self.run(fake)
        #expect(outcome.verified && outcome.attempts == 1 && outcome.change == .accessibilityTree)
        #expect(sent == 1)
    }

    @Test("phases: settle covers the gap and second read, dispatch the input, verify the polls")
    func phases() async throws {
        let fake = FakeSimulator(trees: [tree(count: "0"), tree(count: "1"), tree(count: "1")])
        let outcome = try await Verifier.run(styles: [nil], timeout: .seconds(2), dependencies: fake.dependencies, initialTree: tree(count: "0")) { _ in
            fake.clock += 0.1
        }
        #expect(outcome.verified)
        #expect(abs(outcome.phases.settle - 0.5) < 0.001)
        #expect(abs(outcome.phases.dispatch - 0.1) < 0.001)
        #expect(abs(outcome.phases.verify - 1.0) < 0.001)
    }

    @Test("the verified line lists up to three changes and ends with the timing suffix; a failure names what it ignored, and says not retried only for live text")
    func humanLines() throws {
        let request = VerifyRequest(
            command: "tap", subject: "Tap on id=x", target: "id=x", backend: StubBackend(session: RecordingInputSession()),
            device: DeviceID(rawValue: "emulator-5556", platform: .android), options: try VerificationOptions.parse(["--verify"]), styles: [.simulator, .physical]
        )
        var outcome = Verifier.Outcome(verified: true, attempts: 1, change: .accessibilityTree, style: .simulator, summary: "first")
        outcome.changes = [
            VerifyChange(kind: .changed, node: "switch id=a", field: "checked", old: "false", new: "true"),
            VerifyChange(kind: .added, node: #"button "Save""#),
            VerifyChange(kind: .removed, node: "text id=old"),
            VerifyChange(kind: .changed, node: "text id=b", field: "frame", old: "(0, 0) 1x1", new: "(0, 9) 1x1"),
        ]
        outcome.changesTruncated = 2
        outcome.phases = VerifyPhases(settle: 0.3, resolve: 0.1, dispatch: 0.1, verify: 1.2)
        #expect(VerifyOutput.verifiedLine(outcome, for: request)
            == #"✓ Tap on id=x verified: accessibility tree changed (checked of switch id=a "false" to "true"; button "Save" added; text id=old removed; and 3 more), attempt 1 of 2, simulator style (settle 0.4 s, tap 0.1 s, verify 1.2 s)"#)

        var failed = Verifier.Outcome(verified: false, attempts: 1, change: .none, style: .simulator, summary: nil)
        failed.ignored = [VerifyIgnored(node: "live-ticker-heart-rate", reason: .live), VerifyIgnored(node: "live-ticker-steps", reason: .live)]
        let line = VerifyOutput.unverifiedLine(failed, for: request)
        #expect(line.contains("Ignored live: live-ticker-heart-rate, live-ticker-steps, which changed without the input; not retried."))
        failed.ignored = [VerifyIgnored(node: "spinner", reason: .volatile)]
        #expect(VerifyOutput.unverifiedLine(failed, for: request).contains("Ignored already changing before the input: spinner, which changed without the input. "))
    }
}
