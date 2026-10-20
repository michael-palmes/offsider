import ArgumentParser

/// `list-devices`, the name before 0.13.0: the same list, and no subcommands, so it never reaches `devices add`.
struct ListDevicesAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-devices", abstract: "Lists available devices and the IDs other commands take.", shouldDisplay: false)

    @OptionGroup var options: DeviceListOptions

    func run() async throws {
        try await ListDevices.list(options)
    }
}
