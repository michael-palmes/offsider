import ArgumentParser
import FBSimulatorControl
import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid
@testable import Offsider

@Suite("Device settings")
@MainActor
struct DeviceSettingsTests {
    @Test("each content size names idb's content size category of the same name")
    func iosIndexes() {
        let pairs: [(ContentSizeCategory, FBSimulatorContentSizeCategory)] = [
            (.extraSmall, .extraSmall), (.small, .small), (.medium, .medium), (.large, .large),
            (.extraLarge, .extraLarge), (.extraExtraLarge, .extraExtraLarge), (.extraExtraExtraLarge, .extraExtraExtraLarge),
            (.accessibilityMedium, .accessibilityMedium), (.accessibilityLarge, .accessibilityLarge),
            (.accessibilityExtraLarge, .accessibilityExtraLarge), (.accessibilityExtraExtraLarge, .accessibilityExtraExtraLarge),
            (.accessibilityExtraExtraExtraLarge, .accessibilityExtraExtraExtraLarge),
        ]
        #expect(pairs.count == ContentSizeCategory.allCases.count)
        for (category, idb) in pairs {
            #expect(category.iosIndex == idb.rawValue, "\(category.rawValue)")
            #expect(ContentSizeCategory(iosIndex: idb.rawValue) == category)
        }
        #expect(ContentSizeCategory(iosIndex: 0) == nil)
        #expect(ContentSizeCategory(iosIndex: 13) == nil)
    }

    @Test("Android font scales grow with the size, large is 1.0, and each scale reads back as its own size")
    func androidScales() {
        let scales = ContentSizeCategory.allCases.map(\.androidFontScale)
        #expect(zip(scales, scales.dropFirst()).allSatisfy { $0 < $1 })
        #expect(ContentSizeCategory.large.androidFontScale == 1.0)
        #expect(ContentSizeCategory.nearest(androidFontScale: 1.0) == .large)
        #expect(ContentSizeCategory.nearest(androidFontScale: 1.12) == .extraLarge)
        #expect(ContentSizeCategory.nearest(androidFontScale: 9) == .accessibilityExtraExtraExtraLarge)
        for category in ContentSizeCategory.allCases {
            #expect(ContentSizeCategory.nearest(androidFontScale: category.androidFontScale) == category)
        }
    }

    @Test("reset is large, and an unknown size lists every name")
    func parseSizes() throws {
        #expect(try ContentSizeCategory.parse("reset") == .large)
        #expect(try ContentSizeCategory.parse("Accessibility-Large") == .accessibilityLarge)
        #expect(throws: DeviceSettingsError("Unknown size 'xl'. Use one of: extra-small, small, medium, large, extra-large, extra-extra-large, extra-extra-extra-large, accessibility-medium, accessibility-large, accessibility-extra-large, accessibility-extra-extra-large, accessibility-extra-extra-extra-large, reset.")) {
            try ContentSizeCategory.parse("xl")
        }
    }

    @Test("the home edge lands on the physical bottom edge, on the side UIKit's name gives", arguments: [
        (DeviceOrientation.landscapeLeft, (x: 0.0, y: 201.0)),
        (.landscapeRight, (x: 874.0, y: 201.0)),
        (.portraitUpsideDown, (x: 201.0, y: 0.0)),
        (.portrait, (x: 201.0, y: 874.0)),
    ] as [(DeviceOrientation, (x: Double, y: Double))])
    func homeEdge(orientation: DeviceOrientation, homeEdgeMidpoint: (x: Double, y: Double)) {
        let physical = OrientationCoordinateMath.translateToPhysical(
            x: homeEdgeMidpoint.x, y: homeEdgeMidpoint.y,
            orientation: orientation.coordinateOrientation, portraitWidth: 402, portraitHeight: 874
        )
        #expect(abs(physical.y - 874) < 0.001)
        #expect(abs(physical.x - 201) < 0.001)
    }

    @Test("names, coordinate orientations, idb events and Android rotations round trip", arguments: DeviceOrientation.allCases)
    func mappingRoundTrips(orientation: DeviceOrientation) {
        #expect(DeviceOrientation(coordinateOrientation: orientation.coordinateOrientation) == orientation)
        #expect(DeviceOrientation(androidRotation: orientation.androidRotation) == orientation)
        #expect(FBSimulatorHIDDeviceOrientation(rawValue: orientation.iosEventValue) != nil)
        #expect(orientation.isLandscape == orientation.rawValue.hasPrefix("landscape"))
    }

    @Test("idb's event 3 turns the app to landscape-right and 4 to landscape-left, as measured on iOS 27")
    func measuredIOSEvents() {
        #expect(DeviceOrientation.landscapeRight.iosEventValue == 3)
        #expect(DeviceOrientation.landscapeLeft.iosEventValue == 4)
        #expect(Set(DeviceOrientation.allCases.map(\.iosEventValue)).count == 4)
        #expect(Set(DeviceOrientation.allCases.map(\.androidRotation)) == [0, 1, 2, 3])
    }

    @Test("JSON lines keep their field order and nulls")
    func reports() {
        #expect(DeviceSettingsReport.appearance(.dark, previous: .light) == #"{"appearance":"dark","previous":"light"}"#)
        #expect(DeviceSettingsReport.appearance(.light, previous: nil) == #"{"appearance":"light","previous":null}"#)
        #expect(DeviceSettingsReport.contentSize(ContentSizeReading(category: .accessibilityLarge, fontScale: nil), previous: ContentSizeReading(category: .large, fontScale: nil))
            == #"{"contentSize":"accessibility-large","previous":"large","fontScale":null}"#)
        #expect(DeviceSettingsReport.contentSize(ContentSizeReading(category: .extraExtraLarge, fontScale: 1.3), previous: nil)
            == #"{"contentSize":"extra-extra-large","previous":null,"fontScale":1.3}"#)
        #expect(DeviceSettingsReport.orientation(.landscapeRight, previous: .portrait, screen: UIScreenInfo(width: 874, height: 402))
            == #"{"orientation":"landscape-right","previous":"portrait","screen":{"width":874,"height":402}}"#)
    }

    @Test("human lines say what changed")
    func lines() {
        #expect(AppearanceCommand.line(.dark, previous: .light) == "Appearance: dark (was light)")
        #expect(AppearanceCommand.line(.light, previous: .light) == "Appearance: light")
        #expect(ContentSizeCommand.line(ContentSizeReading(category: .accessibilityLarge, fontScale: nil), previous: ContentSizeReading(category: .large, fontScale: nil))
            == "Content size: accessibility-large (was large)")
        #expect(ContentSizeCommand.line(ContentSizeReading(category: .extraLarge, fontScale: 1.15), previous: nil)
            == "Content size: extra-large, font scale 1.15")
        #expect(OrientationCommand.line(.landscapeRight, screen: UIScreenInfo(width: 874, height: 402), platform: .ios)
            == "Orientation: landscape-right (874 x 402 pt)")
        #expect(OrientationCommand.line(.portrait, screen: UIScreenInfo(width: 411.43, height: 923.43), platform: .android)
            == "Orientation: portrait (411.43 x 923.43 dp)")
    }

    @Test("an Android night mode of auto reads as a schedule, and setting dark still works with no previous value")
    @MainActor
    func scheduledNightMode() async throws {
        let (backend, _, emulator) = try AndroidDeviceControlsTests.setUp(night: "auto")
        let device = AndroidDeviceControlsTests.device

        #expect(try await AppearanceCommand.report(nil, json: false, on: device, settings: backend) == "Appearance: auto (follows the system schedule)")
        #expect(try await AppearanceCommand.report(nil, json: true, on: device, settings: backend) == #"{"appearance":"auto","previous":null}"#)
        #expect(try await AppearanceCommand.report(.dark, json: false, on: device, settings: backend) == "Appearance: dark")
        #expect(emulator.night == "yes")
        #expect(try await AppearanceCommand.report(.light, json: true, on: device, settings: backend) == #"{"appearance":"light","previous":"dark"}"#)
    }

    @Test("an iOS content size index outside the known sizes is an error, not large", arguments: [0, 13])
    func unknownIOSContentSize(index: Int) throws {
        let device = DeviceID(rawValue: "SIM", platform: .ios)
        #expect(throws: CLIError.self) { try IOSBackend.contentSizeReading(iosIndex: index, on: device) }
        #expect(try IOSBackend.contentSizeReading(iosIndex: 4, on: device).category == .large)
    }

    @Test("bad values are usage errors naming the choices", arguments: [
        (["appearance", "dim"], "Unknown appearance 'dim'. Use light or dark."),
        (["content-size", "xl"], "Unknown size 'xl'."),
        (["orientation", "sideways"], "Unknown orientation 'sideways'. Use one of: portrait, landscape-left, landscape-right, portrait-upside-down."),
        (["orientation", "portrait", "--timeout", "0"], "--timeout must be from 0.5 to 60 seconds; got 0."),
        (["shake"], "shake is iOS only: Android emulators have no shake event."),
    ])
    func validation(arguments: [String], message: String) {
        do {
            _ = try OffsiderCommand.parseAsRoot(arguments + ["--device", arguments == ["shake"] ? "Pixel_9" : "emulator-5554"])
            Issue.record("expected a usage error")
        } catch {
            #expect(OffsiderCommand.exitCode(for: error) == .validationFailure)
            #expect(OffsiderCommand.message(for: error).contains(message))
        }
    }

    @Test("reading needs no value, and values are case-insensitive")
    func optionalValues() throws {
        #expect(try AppearanceCommand.parse(["--device", "x"]).target() == nil)
        #expect(try AppearanceCommand.parse(["Dark", "--device", "x"]).target() == .dark)
        #expect(try OrientationCommand.parse(["Landscape-Left", "--device", "x"]).target() == .landscapeLeft)
        #expect(try ContentSizeCommand.parse(["reset", "--device", "x", "--json"]).target() == .large)
    }

    @Test("an iOS orientation timeout names the target, the wait and the device", arguments: [
        (DeviceOrientation.landscapeRight, "The simulator did not turn to landscape-right within 5 s. This iOS runtime may ignore the orientation event Offsider sends, or the frontmost app supports portrait only. Check with `offsider orientation --device D`."),
        (.portraitUpsideDown, "The simulator did not turn to portrait-upside-down within 5 s. This iOS runtime may ignore the orientation event Offsider sends, or the frontmost app does not support portrait-upside-down. Check with `offsider orientation --device D`."),
    ])
    func timeoutMessage(target: DeviceOrientation, message: String) {
        #expect(OrientationCommand.timeoutMessage(target: target, timeout: 5, platform: .ios, device: "D") == message)
    }
}

@Suite("Orientation wait")
@MainActor
struct OrientationWaitTests {
    final class Clock {
        var time: TimeInterval = 0
        var reads: [DeviceOrientation?]
        var requests = 0
        var readCount = 0

        init(reads: [DeviceOrientation?]) {
            self.reads = reads
        }

        func read() -> DeviceOrientation? {
            readCount += 1
            return reads.count > 1 ? reads.removeFirst() : reads.first ?? nil
        }
    }

    private func run(_ clock: Clock, timeout: TimeInterval = 5) async throws -> OrientationWait.Outcome {
        try await OrientationWait.run(
            target: .landscapeRight,
            timeout: timeout,
            read: { clock.read() },
            request: { clock.requests += 1 },
            sleep: { clock.time += Double($0.components.attoseconds) / 1e18 + Double($0.components.seconds) },
            now: { clock.time }
        )
    }

    @Test("already turned is reached on the first read, without sending again")
    func alreadyThere() async throws {
        let clock = Clock(reads: [.landscapeRight])
        #expect(try await run(clock) == .reached)
        #expect(clock.readCount == 1)
        #expect(clock.requests == 0)
    }

    @Test("a turn that lands after a few polls is reached")
    func reachedLater() async throws {
        let clock = Clock(reads: [.portrait, .portrait, .landscapeRight])
        #expect(try await run(clock) == .reached)
        #expect(clock.readCount == 3)
        #expect(abs(clock.time - 0.2) < 0.0001)
    }

    @Test("a device that never turns times out with its last reading, after one resend halfway")
    func timesOut() async throws {
        let clock = Clock(reads: [.portrait])
        #expect(try await run(clock, timeout: 1) == .timedOut(last: .portrait))
        #expect(clock.requests == 1)
        #expect(clock.time >= 1)
        #expect(clock.time < 1.2)
    }
}
