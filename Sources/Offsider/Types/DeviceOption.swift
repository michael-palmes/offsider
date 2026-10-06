import ArgumentParser

/// `--device`, or `OFFSIDER_DEVICE` when it is absent, for commands that need a device.
protocol RequiredDeviceOption: ParsableArguments {
    var explicitID: String? { get }
}

extension RequiredDeviceOption {
    /// Empty only before `validate()` has run.
    var id: String { DeviceDefault.resolve(explicit: explicitID)?.id ?? "" }
    var source: DeviceSource? { DeviceDefault.resolve(explicit: explicitID)?.source }

    func validateDevice() throws {
        guard DeviceDefault.resolve(explicit: explicitID) != nil else { throw ValidationError(DeviceDefault.missingMessage) }
    }
}

/// `--device` plus `--wait-lock`, for commands that can lock the device.
struct DeviceOption: RequiredDeviceOption {
    @Option(name: .customLong("device"), help: ArgumentHelp("The device ID from `offsider list-devices` (default OFFSIDER_DEVICE).", valueName: "id"))
    var explicitID: String?

    @OptionGroup
    var lock: WaitLockOption

    var waitLock: Double? { lock.waitLock }

    func validate() throws { try validateDevice() }
}

/// `--device` alone, for commands that never lock the device.
struct ReadDeviceOption: RequiredDeviceOption {
    @Option(name: .customLong("device"), help: ArgumentHelp("The device ID from `offsider list-devices` (default OFFSIDER_DEVICE).", valueName: "id"))
    var explicitID: String?

    func validate() throws { try validateDevice() }
}

struct WaitLockOption: ParsableArguments {
    @Option(
        name: .customLong("wait-lock"),
        help: ArgumentHelp(
            "Seconds to wait while another Offsider command holds the device (0 to 600; default OFFSIDER_WAIT_LOCK, else fail at once with exit 8).",
            valueName: "seconds"
        )
    )
    var waitLock: Double?

    func validate() throws {
        if let waitLock, !(waitLock.isFinite && (0...DeviceClaims.maximumWait).contains(waitLock)) {
            throw ValidationError("--wait-lock must be from 0 to \(Int(DeviceClaims.maximumWait)) seconds.")
        }
    }
}

struct OptionalDeviceOption: ParsableArguments {
    @Option(name: .customLong("device"), help: ArgumentHelp("Also check this device (default OFFSIDER_DEVICE).", valueName: "id"))
    var explicitID: String?

    var id: String? { DeviceDefault.resolve(explicit: explicitID)?.id }
    var source: DeviceSource? { DeviceDefault.resolve(explicit: explicitID)?.source }
}
