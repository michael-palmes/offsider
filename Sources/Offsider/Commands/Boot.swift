import ArgumentParser
import Foundation
import OffsiderAndroid
import OffsiderCore

struct Boot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an Android emulator (AVD) and wait until it has booted; prints its serial.",
        discussion: """
        The emulator runs detached with its window (use --headless to hide it) and always with -no-metrics; its output \
        goes to $TMPDIR/offsider-boot-<avd>.log. --memory, --no-snapshot-load and --emulator-arg add to that launch; \
        --emulator-arg refuses flags that open a listener, send metrics or replace Offsider's own options. An AVD that is \
        already running is not started again: boot prints its serial, waiting first if it is still booting, and says \
        which launch options it ignored. Ctrl+C stops the wait, not the emulator.

        Examples:
          offsider boot Pixel_9
          DEVICE=$(offsider boot Pixel_9 --headless)
          offsider boot Pixel_9 --memory 4096 --no-snapshot-load --emulator-arg -gpu --emulator-arg host
        """
    )

    @Argument(help: ArgumentHelp("The AVD name from `offsider list-devices`.", valueName: "avd"))
    var avd: String

    @Flag(name: .customLong("headless"), help: "Run the emulator without its window.")
    var headless = false

    @Option(name: .customLong("timeout"), help: "Seconds to wait for the boot to finish (default: 240).")
    var timeout: Double = 240

    @Option(name: .customLong("memory"), help: ArgumentHelp("RAM for the emulator in MB, from 1024 to 16384 (-memory).", valueName: "MB"))
    var memory: Int?

    @Flag(name: .customLong("no-snapshot-load"), help: "Cold boot instead of loading the quick-boot snapshot.")
    var noSnapshotLoad = false

    @Option(
        name: .customLong("emulator-arg"),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp("One more token for the emulator command line; repeat for each token, such as --emulator-arg -gpu --emulator-arg host.", valueName: "token")
    )
    var emulatorArguments: [String] = []

    static let allowedTimeout = 10.0...1800.0
    static let allowedMemory = 1024...16384

    func validate() throws {
        switch DeviceIDClassifier.classify(avd) {
        case .iosSimulator:
            throw ValidationError("boot starts Android emulators. Boot an iOS simulator with `xcrun simctl boot <udid>`.")
        case .iosDevice:
            throw ValidationError("boot starts Android emulators, and \(avd) is a physical iPhone or iPad. Turn it on, unlock it and connect its cable, then run `offsider list-devices`.")
        case .androidSerial, .androidNetworkSerial:
            throw ValidationError("boot takes an AVD name, not a serial. Run `offsider list-devices` to see AVD names.")
        case .empty, .unrecognised:
            throw ValidationError("'\(avd)' is not an AVD name. AVD names use letters, digits, '.', '_' and '-'; run `offsider list-devices` to see them.")
        case .androidName:
            break
        }
        guard timeout.isFinite, Self.allowedTimeout.contains(timeout) else {
            throw ValidationError("--timeout must be between 10 and 1800 seconds.")
        }
        if let memory, !Self.allowedMemory.contains(memory) {
            throw ValidationError("--memory must be from 1024 to 16384 MB; got \(memory).")
        }
        if let refusal = EmulatorArguments.refusal(in: emulatorArguments) {
            throw ValidationError(refusal)
        }
    }

    @MainActor
    func run() async throws {
        let logger = OffsiderLogger()
        let booter = EmulatorBooter(host: .live(), log: AndroidBackend.logBridge(logger: logger))
        let request = EmulatorBootRequest(
            avdName: avd,
            headless: headless,
            timeout: .milliseconds(Int((timeout * 1000).rounded())),
            memoryMB: memory,
            noSnapshotLoad: noSnapshotLoad,
            extraArguments: emulatorArguments
        )
        let result = try await booter.boot(request) { line in
            print(line, to: &standardError)
        }
        print(result.serial)
    }
}
