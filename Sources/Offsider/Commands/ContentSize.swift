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
        On iOS a running app may keep some old text measurements after a change (cut-short headers, a sheet at its \
        old height), so with an app in front a note names the restart that shows the new size. Android recreates the \
        app's screen, so it needs none.

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
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger, locking: target != nil)
        let console = Console.current
        let (current, previous, note) = try await console.progress(target.map { "Setting \($0.rawValue)" } ?? "Reading the content size") {
            try await route.backend.prepare()
            let device = try await route.backend.requireBootedDevice(route.device).id
            guard let settings = route.backend as? any DeviceSettingsControlling else {
                throw CLIError(errorDescription: "content-size is not available for \(deviceOption.id).", reason: .notSupported)
            }
            guard let target else { return (try await settings.contentSize(on: device), nil as ContentSizeReading?, nil as Notice?) }
            let previous = try? await settings.contentSize(on: device)
            try await settings.setContentSize(target, on: device)
            let current = try await settings.contentSize(on: device)
            return (current, previous, await Self.restartNote(current, previous: previous, on: route))
        }
        let text = json ? DeviceSettingsReport.contentSize(current, previous: previous) : Self.line(current, previous: previous)
        let person = DevicePersonView.contentSize(current, previous: previous, setting: target != nil)
        DevicePersonView.emit(text, json: json, person: person, notices: note.map { [$0] } ?? [], console: console)
    }

    /// What is in front once the size changed: the home screen, an app, or nothing a cheap read could name.
    enum FrontApp: Equatable {
        case home
        case app(String)
        case unknown
    }

    /// After a change on iOS with an app in front: a running app can keep old text measurements until it restarts. Android recreates the activity, so never there.
    @MainActor
    static func restartNote(
        _ current: ContentSizeReading, previous: ContentSizeReading?, on route: DeviceRouter.Route,
        processPath: (Int) -> String? = { Int32(exactly: $0).flatMap(ProcessPath.of(pid:)) }
    ) async -> Notice? {
        let device = route.device
        guard device.platform == .ios, previous?.category != current.category else { return nil }
        // An iPhone needs the runner to say what is in front, which costs seconds, so its only pinned app stands in.
        let front: FrontApp = device.isPhysicalIOSDevice
            ? route.allowance.flatMap { $0.pinnedApps.count == 1 ? .app($0.pinnedApps[0]) : nil } ?? .unknown
            : await simulatorFront(on: route.backend, device: device, processPath: processPath)
        return restartNote(front: front, device: device)
    }

    /// One point read at the screen's centre, a fraction of a tree read; SpringBoard answering there is the home screen.
    @MainActor
    static func simulatorFront(on backend: any DeviceBackend, device: DeviceID, processPath: (Int) -> String?) async -> FrontApp {
        guard let prober = backend as? any PresentationProbing, let size = try? await backend.screenSize(for: device), size.width > 0, size.height > 0,
              let hit = try? await prober.probe(at: UIPoint(x: size.width / 2, y: size.height / 2), on: device),
              let pid = hit.iosPID, let path = processPath(pid) else { return .unknown }
        if SimulatorHomePress.isSpringBoard(path: path) { return .home }
        return ForegroundApp.bundleIdentifier(atExecutable: path).map(FrontApp.app) ?? .unknown
    }

    static func restartNote(front: FrontApp, device: DeviceID) -> Notice? {
        let app: String
        switch front {
        case .home: return nil
        case .app(let id): app = (try? ExpoDevClient.validate(appID: id)) ?? "<bundle-id>"
        case .unknown: app = "<bundle-id>"
        }
        let restart = "offsider app launch --restart --app \(app) --device \(device.rawValue)"
        let name = app == "<bundle-id>" ? "The app in front" : app
        return .note(
            "An open app keeps old sizes",
            agent: "\(name) may keep some old text measurements until it restarts, so text cut short now may be stale rather than a layout fault. Run `\(restart)` (for an Expo dev client, run rn open again with --restart).",
            see: app == "<bundle-id>" ? nil : restart, label: "Try"
        )
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
