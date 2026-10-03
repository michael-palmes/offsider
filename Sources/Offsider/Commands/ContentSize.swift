import ArgumentParser
import Foundation
import OffsiderCore

struct ContentSizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "content-size",
        abstract: "Read or set the text size (Dynamic Type on iOS, font scale on Android).",
        discussion: """
        Sizes: extra-small, small, medium, large (the default), extra-large, extra-extra-large, extra-extra-extra-large, \
        accessibility-medium, accessibility-large, accessibility-extra-large, accessibility-extra-extra-large, \
        accessibility-extra-extra-extra-large. reset means large. Without a value, prints the current size.
        On Android each size is a font scale (large is 1.0); a scale set elsewhere reads as the nearest size.

        Examples:
          offsider content-size --device DEVICE_ID
          offsider content-size accessibility-large --device DEVICE_ID
          offsider content-size reset --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("A size, or reset; omit to read the current size.", valueName: "size|reset"))
    var value: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        _ = try target()
    }

    func target() throws -> ContentSizeCategory? {
        guard let value else { return nil }
        do {
            return try ContentSizeCategory.parse(value)
        } catch let error as DeviceSettingsError {
            throw ValidationError(error.message)
        }
    }

    func run() async throws {
        let target = try target()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        try await route.backend.prepare()
        let device = try await route.backend.requireBootedDevice(route.device).id
        guard let settings = route.backend as? any DeviceSettingsControlling else {
            throw CLIError(errorDescription: "content-size is not available for \(deviceOption.id).")
        }

        guard let target else {
            let current = try await settings.contentSize(on: device)
            print(json ? DeviceSettingsReport.contentSize(current, previous: nil) : Self.line(current, previous: nil))
            return
        }
        let previous = try? await settings.contentSize(on: device)
        try await settings.setContentSize(target, on: device)
        let current = try await settings.contentSize(on: device)
        print(json ? DeviceSettingsReport.contentSize(current, previous: previous) : Self.line(current, previous: previous))
    }

    static func line(_ current: ContentSizeReading, previous: ContentSizeReading?) -> String {
        var text = "Content size: \(current.category.rawValue)"
        if let previous, previous.category != current.category {
            text += " (was \(previous.category.rawValue))"
        }
        if let scale = current.fontScale {
            text += ", font scale \(DeviceSettingsReport.number(scale))"
        }
        return text
    }
}
