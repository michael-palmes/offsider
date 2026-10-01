import ArgumentParser

struct DeviceOption: ParsableArguments {
    @Option(name: .customLong("device"), help: ArgumentHelp("The device ID from `offsider list-devices`.", valueName: "id"))
    var id: String
}

struct OptionalDeviceOption: ParsableArguments {
    @Option(name: .customLong("device"), help: ArgumentHelp("Also check this device.", valueName: "id"))
    var id: String?
}
