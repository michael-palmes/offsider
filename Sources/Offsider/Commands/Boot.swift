import ArgumentParser
import Foundation
import OffsiderAndroid
import OffsiderCore

struct Boot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an Android emulator (AVD) and wait until it has booted; prints its serial.",
        discussion: """
        The emulator runs detached with its window (use --headless to hide it), -no-metrics and nothing else; its output \
        goes to $TMPDIR/offsider-boot-<avd>.log. An AVD that is already running is not started again: boot prints its \
        serial, waiting first if it is still booting. Ctrl+C stops the wait, not the emulator.

        Examples:
          offsider boot Pixel_9
          DEVICE=$(offsider boot Pixel_9 --headless)
        """
    )

    @Argument(help: ArgumentHelp("The AVD name from `offsider list-devices`.", valueName: "avd"))
    var avd: String

    @Flag(name: .customLong("headless"), help: "Run the emulator without its window.")
    var headless = false

    @Option(name: .customLong("timeout"), help: "Seconds to wait for the boot to finish (default: 240).")
    var timeout: Double = 240

    static let allowedTimeout = 10.0...1800.0

    func validate() throws {
        switch DeviceIDClassifier.classify(avd) {
        case .iosSimulator:
            throw ValidationError("boot starts Android emulators. Boot an iOS simulator with `xcrun simctl boot <udid>`.")
        case .androidSerial:
            throw ValidationError("boot takes an AVD name, not a serial. Run `offsider list-devices` to see AVD names.")
        case .empty, .unrecognised:
            throw ValidationError("'\(avd)' is not an AVD name. AVD names use letters, digits, '.', '_' and '-'; run `offsider list-devices` to see them.")
        case .androidAVDCandidate:
            break
        }
        guard timeout.isFinite, Self.allowedTimeout.contains(timeout) else {
            throw ValidationError("--timeout must be between 10 and 1800 seconds.")
        }
    }

    @MainActor
    func run() async throws {
        let logger = OffsiderLogger()
        let booter = EmulatorBooter(host: .live(), log: AndroidBackend.logBridge(logger: logger))
        let request = EmulatorBootRequest(avdName: avd, headless: headless, timeout: .milliseconds(Int((timeout * 1000).rounded())))
        let result = try await booter.boot(request) { line in
            print(line, to: &standardError)
        }
        print(result.serial)
    }
}
