import ArgumentParser
import Foundation
import OffsiderCore

struct DescribeUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Describes the UI hierarchy of a booted simulator or a running emulator using accessibility information.",
        discussion: """
        The envelope's screen gives width and height in points (dp on Android), orientation (the shape, portrait \
        or landscape), rotation (degrees anticlockwise from the display's natural orientation), display ({id, \
        platformId}: main, or cover or inner on a foldable) and posture (null unless the device folds). Only the \
        active display is described; --display checks that it is the one you expect.
        """
    )

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var displayOption: DisplayOption

    @OptionGroup
    var appOption: AppOption

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

    @Flag(
        name: .customLong("diff"),
        help: "Print what changed since the previous command's tree for this device (added, changed, removed), or 'unchanged since', or the full text when most of the screen changed. Text only: --summary unless --format text is given."
    )
    var diff = false

    @Flag(name: .customLong("raw-source"), help: ArgumentHelp(visibility: .private))
    var rawSource = false

    func validate() throws {
        _ = try parsedPoint()
        if diff {
            if point != nil {
                throw ValidationError("--diff compares the whole screen; it cannot be used with --point.")
            }
            if output.compact || (output.format.map { $0 != .text } ?? false) {
                throw ValidationError("--diff prints text only; drop --format json, --format ndjson and --compact.")
            }
        }
    }

    /// `--summary` unless the caller chose a text view.
    func diffOptions() throws -> UITreeRenderOptions {
        output.format == .text ? try output.renderOptions() : .summary
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        await appOption.apply(to: route)
        try await route.backend.prepare()
        try await Self.requireActive(displayOption, on: route, deviceName: deviceOption.id)

        if rawSource {
            print(String(decoding: try await Self.rawCapture(on: route), as: UTF8.self))
            return
        }
        print(try await describe(on: route), terminator: "")
    }

    /// The output for one read; with `--diff`, compared against the device's cached tree.
    @MainActor
    func describe(on route: DeviceRouter.Route) async throws -> String {
        let base = diff ? await TreeCache.load(for: route.device, backend: route.backend) : nil
        let tree = await Self.withScreen(try await route.backend.accessibilityTree(for: route.device, point: try parsedPoint()), on: route)
        if point == nil {
            DeviceActivityLedger.current.recordScreen(tree.screen, on: route.device)
        }
        guard diff else {
            return String(decoding: try output.render(tree), as: UTF8.self)
        }
        let usable = base.flatMap { $0.matches(appFrame: tree.applicationFrame, screen: tree.screen) ? $0 : nil }
        let options = try diffOptions()
        let now = TreeCacheEnvironment.current.now()
        return Timings.measure("tree-diff") {
            TreeDiffRenderer.render(tree, base: usable, options: options, now: now)
        }
    }

    /// The accessibility tree covers the active display only, so `--display` must name it.
    @MainActor
    static func requireActive(_ option: DisplayOption, on route: DeviceRouter.Route, deviceName: String) async throws {
        guard let selected = try await option.resolve(on: route.backend, device: route.device, deviceName: deviceName),
              !selected.display.active else {
            return
        }
        throw CLIError(errorDescription: DisplayReport.inactiveDisplay(
            selected.display, posture: selected.list.posture, platform: route.device.platform, device: deviceName
        ), reason: .displayOff)
    }

    /// The platform's unmapped tree with the screen, for the committed tree goldens.
    @MainActor
    static func rawCapture(on route: DeviceRouter.Route) async throws -> Data {
        guard let source = route.backend as? any RawAccessibilitySource else {
            throw CLIError(errorDescription: "--raw-source is not supported for device \(route.device.rawValue).", reason: .notSupported)
        }
        let raw = try await source.rawAccessibilitySource(for: route.device)
        let screen = try? await route.backend.screenInfo(for: route.device)
        return RawTreeCapture.render(platform: route.device.platform, screen: screen, source: raw)
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
