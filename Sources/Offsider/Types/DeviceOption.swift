import ArgumentParser

/// `--device` plus `--wait-lock`, for commands that can lock the device.
struct DeviceOption: ParsableArguments {
    @Option(name: .customLong("device"), help: ArgumentHelp("The device ID from `offsider list-devices`.", valueName: "id"))
    var id: String

    @OptionGroup
    var lock: WaitLockOption

    var waitLock: Double? { lock.waitLock }
}

/// `--device` alone, for commands that never lock the device.
struct ReadDeviceOption: ParsableArguments {
    @Option(name: .customLong("device"), help: ArgumentHelp("The device ID from `offsider list-devices`.", valueName: "id"))
    var id: String
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
    @Option(name: .customLong("device"), help: ArgumentHelp("Also check this device.", valueName: "id"))
    var id: String?
}
