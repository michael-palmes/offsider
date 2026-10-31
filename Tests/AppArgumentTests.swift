import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("--app and --bundle-id")
@MainActor
struct AppArgumentTests {
    /// Every command in the tree with its words, found from the help so a new command cannot slip past.
    static func commands(_ type: any ParsableCommand.Type = OffsiderCommand.self, path: [String] = []) -> [(path: [String], type: any ParsableCommand.Type)] {
        let configuration = type.configuration
        let children = configuration.subcommands + configuration.groupedSubcommands.flatMap(\.subcommands)
        return [(path, type)] + children.flatMap { child in
            commands(child, path: path + [child._commandName])
        }
    }

    /// Allow-list and login records, not a device a command drives: each validates its own ids.
    static let ownIDs = ["devices add", "credential"]

    static let takingApp: [(path: [String], type: any ParsableCommand.Type, option: String)] = commands().compactMap { entry in
        let help = entry.type.helpMessage(columns: 200)
        guard !ownIDs.contains(entry.path.joined(separator: " ")) else { return nil }
        if help.contains("--app <") { return (entry.path, entry.type, "--app") }
        if help.contains("--bundle-id <") { return (entry.path, entry.type, "--bundle-id") }
        return nil
    }

    @Test("the walk finds the commands that name an app")
    func findsCommands() {
        let names = Self.takingApp.map { $0.path.joined(separator: " ") }
        for known in ["tap", "logs", "notifications", "permission", "app launch", "rn open", "rn prepare", "record-video", "login"] {
            #expect(names.contains(known), "\(known)")
        }
    }

    @Test("every command that takes an app refuses a padded id at parsing, before any device is named")
    func paddedRefusedAtParsing() {
        for entry in Self.takingApp {
            do {
                _ = try OffsiderCommand.parseAsRoot(entry.path + [entry.option, " com.android.chrome"])
                Issue.record("\(entry.path.joined(separator: " ")) took a padded id")
            } catch {
                #expect(OffsiderCommand.message(for: error).contains("is not a bundle ID"), "\(entry.path.joined(separator: " ")): \(OffsiderCommand.message(for: error))")
            }
        }
    }

    @Test("every command that takes an app hands it to routing's allowance check")
    func namedAtRouting() {
        for entry in Self.takingApp {
            #expect(entry.type is any AppNaming.Type, "\(entry.path.joined(separator: " ")) takes \(entry.option) but routing never sees it")
        }
    }

    @Test("what a command names reaches routing")
    func namedAppValue() throws {
        #expect((try OffsiderCommand.parseAsRoot(["tap", "-x", "1", "-y", "1", "--app", "com.example.app", "--device", "emulator-5554"]) as? any AppNaming)?.namedApp == "com.example.app")
        #expect((try OffsiderCommand.parseAsRoot(["app", "stop", "--app", "com.example.app", "--device", "emulator-5554"]) as? any AppNaming)?.namedApp == "com.example.app")
        #expect((try OffsiderCommand.parseAsRoot(["rn", "prepare", "--bundle-id", "com.example.app", "--device", "emulator-5554"]) as? any AppNaming)?.namedApp == "com.example.app")
    }

    static let pixel = DeviceID(rawValue: "R58MFAKE01", platform: .android)

    static func allowance(apps: [String]) -> DeviceAllowance {
        DeviceAllowance(platform: .android, key: pixel.rawValue, name: "Test Pixel", added: Date(), expires: nil, apps: apps)
    }

    static func gate(_ allowance: DeviceAllowance) -> DevicePolicyGate {
        .fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [allowance])))
    }

    @Test("routing refuses an app outside the pins or on the deny-list, whichever command names it", arguments: [
        ("com.example.other", ["com.example.pinned"]),
        ("com.android.chrome", []),
    ] as [(String, [String])])
    func routingRefuses(app: String, apps: [String]) {
        let allowance = Self.allowance(apps: apps)
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: []), device: Self.pixel, allowance: allowance)
        let error = #expect(throws: CLIError.self) { try DeviceRouter.requireNamedApp(app, on: route, gate: Self.gate(allowance)) }
        #expect(error?.reason == .appNotAllowed)
    }

    @Test("routing passes an allowed app, no app and every simulator or emulator")
    func routingPasses() throws {
        let allowance = Self.allowance(apps: ["com.example.pinned"])
        let phone = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: []), device: Self.pixel, allowance: allowance)
        try DeviceRouter.requireNamedApp("com.example.pinned", on: phone, gate: Self.gate(allowance))
        try DeviceRouter.requireNamedApp(nil, on: phone, gate: Self.gate(allowance))
        let emulator = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: []), device: DeviceID(rawValue: "emulator-5554", platform: .android))
        try DeviceRouter.requireNamedApp("com.android.chrome", on: emulator, gate: Self.gate(allowance))
    }

    // MARK: Printed commands

    final class Phone: FakeDeviceBackend, AppTargetSelecting {
        var selected: String?

        func selectApp(_ appID: String, on id: DeviceID) -> Bool {
            defer { selected = appID }
            return selected != appID
        }

        func selectedApp(on id: DeviceID) -> String? { selected }
    }

    @Test("a printed command names the app only where a new process would not know it", arguments: [
        ([] as [String], "com.example.app", " --app com.example.app"),
        (["*"], "com.example.app", " --app com.example.app"),
        (["com.example.app", "com.example.two"], "com.example.app", " --app com.example.app"),
        (["com.example.app"], "com.example.app", ""),
        ([], nil, ""),
        ([], "com.example.bad;id", ""),
    ] as [([String], String?, String)])
    func appArgument(apps: [String], selected: String?, argument: String) {
        let phone = Phone(platform: .android, trees: [])
        phone.selected = selected
        let route = DeviceRouter.Route(backend: phone, device: Self.pixel, allowance: Self.allowance(apps: apps))
        #expect(route.appArgument == argument)
    }

    @Test("a simulator's printed command needs no app")
    func noAppArgumentWithoutAllowance() {
        let phone = Phone(trees: [])
        phone.selected = "com.example.app"
        #expect(DeviceRouter.Route(backend: phone, device: DeviceID(rawValue: "emulator-5554", platform: .android)).appArgument == "")
    }

    @Test("the describe-ui hint uses the route noted for the device, with the app before --device")
    func describeHint() {
        let allowance = Self.allowance(apps: [])
        DevicePolicyGate.$current.withValue(Self.gate(allowance)) {
            let scope = CommandScope()
            scope.bannerNote = { _ in }
            #expect(scope.describeHint(device: Self.pixel.rawValue) == "offsider describe-ui --summary --device R58MFAKE01")
            let phone = Phone(platform: .android, trees: [])
            phone.selected = "com.example.app"
            scope.noteRoute(DeviceRouter.Route(backend: phone, device: Self.pixel, allowance: allowance))
            #expect(scope.describeHint(device: Self.pixel.rawValue) == "offsider describe-ui --summary --app com.example.app --device R58MFAKE01")
        }
    }
}
