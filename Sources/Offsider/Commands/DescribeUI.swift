import ArgumentParser
import Foundation
import OffsiderCore

struct DescribeUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Describes the UI hierarchy of a booted simulator or a running emulator using accessibility information."
    )

    @OptionGroup
    var deviceOption: DeviceOption

    @Option(
        name: .customLong("point"),
        help: ArgumentHelp(
            "Describe only the accessibility element at screen coordinates x,y.",
            valueName: "x,y"
        )
    )
    var point: String?

    @OptionGroup(title: "Output")
    var output: DescribeUIOutputOptions

    func validate() throws {
        _ = try parsedPoint()
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        try await route.backend.prepare()

        let tree = try await route.backend.accessibilityTree(for: route.device, point: try parsedPoint())
        print(String(decoding: try output.render(await Self.withScreen(tree, on: route)), as: UTF8.self), terminator: "")
    }

    /// The tree with the screen the envelope reports, when the device can say.
    @MainActor
    static func withScreen(_ tree: UITree, on route: DeviceRouter.Route) async -> UITree {
        var tree = tree
        tree.screen = try? await route.backend.screenInfo(for: route.device)
        return tree
    }

    func parsedPoint() throws -> UIPoint? {
        guard let point else {
            return nil
        }

        let coordinates = point
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard coordinates.count == 2,
              let x = Double(coordinates[0]),
              let y = Double(coordinates[1]),
              x.isFinite,
              y.isFinite,
              x >= 0,
              y >= 0
        else {
            throw ValidationError("--point must be in the form x,y using non-negative numbers.")
        }

        return UIPoint(x: x, y: y)
    }
}
