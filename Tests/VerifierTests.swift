import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import OffsiderCore
@testable import Offsider

@MainActor
private final class FakeSimulator {
    var clock: TimeInterval = 0
    var trees: [AccessibilitySnapshot]
    var screens: [Data]
    private(set) var treeReads = 0
    private(set) var screenReads = 0

    init(trees: [AccessibilitySnapshot], screens: [Data] = []) {
        self.trees = trees
        self.screens = screens
    }

    var dependencies: Verifier.Dependencies {
        Verifier.Dependencies(
            snapshot: { [unowned self] in
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
                clock += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            },
            now: { [unowned self] in clock }
        )
    }
}

private func tree(count: String, extra: [AccessibilitySnapshot.Node] = []) -> AccessibilitySnapshot {
    let frame = AccessibilitySnapshot.Frame(x: 0, y: 0, width: 64, height: 128)
    let label = AccessibilitySnapshot.Node(type: "StaticText", identifier: "tap-count", value: count)
    return AccessibilitySnapshot(roots: [
        AccessibilitySnapshot.Node(type: "Application", label: "Playground", frame: frame, children: [label] + extra)
    ])
}

private let emptyTree = AccessibilitySnapshot(roots: [AccessibilitySnapshot.Node(type: "Application")])

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
        #expect(actions.count == 1)
        #expect(retries.isEmpty)
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
        func spinner(_ value: String) -> AccessibilitySnapshot {
            tree(count: "0", extra: [AccessibilitySnapshot.Node(type: "ProgressIndicator", identifier: "spinner", value: value)])
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

    @Test("The status bar band is excluded only in portrait")
    func statusBandOnlyInPortrait() {
        let png = screen(shade: 10)
        let portrait = AccessibilitySnapshot.Frame(x: 0, y: 0, width: 32, height: 64)
        let landscape = AccessibilitySnapshot.Frame(x: 0, y: 0, width: 64, height: 32)
        #expect(Verifier.statusBandPixels(pngData: png, screenFrame: portrait) == 120)
        #expect(Verifier.statusBandPixels(pngData: png, screenFrame: landscape) == 0)
        #expect(Verifier.statusBandPixels(pngData: png, screenFrame: nil) == 0)
    }
}
