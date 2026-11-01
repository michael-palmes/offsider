import ArgumentParser
import Foundation
import OffsiderCore

struct AppPrefsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefs",
        abstract: "List an app's preference names and types, never their values.",
        discussion: """
        Android only. Lists each file in the app's shared_prefs folder with its key names and types. Values never leave \
        the device: its own `grep -o` prints only each key's opening tag, and no option asks for a value, a length or a \
        hash. It needs a debuggable build, as `run-as` does; a release build exits 1 with not_debuggable. An active \
        evidence run gets one manifest line with the key count, and nothing goes in the tree cache. A key name shaped \
        like a token is masked. DataStore and other stores are not read.

        Example:
          offsider app prefs --app com.example.app --device DEVICE_ID --json
        """
    )

    @OptionGroup
    var appOption: AppTargetOption

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: ReadDeviceOption

    @MainActor
    func run() async throws {
        try StayAwakeCommand.requireAndroid(deviceOption.id, command: "app prefs")
        let route = try await DeviceRouter.route(deviceOption.id, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "prefs")
        let recorder = EvidenceRecorder.current
        let token = try recorder.begin(device: route.device, kind: "prefs")
        let preferences = try await Console.current.progress("Reading \(app)'s preference names") {
            let backend = try AppTarget.manager(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.appPreferences(app, on: id)
        }
        recorder.update(token) { $0.entries = preferences.keyCount }
        let text = json ? AppManagementReport.preferences(preferences, on: route.device) : Self.lines(preferences)
        DevicePersonView.emit(text, json: json, person: Self.person(preferences), console: .current)
    }

    static func lines(_ preferences: AppPreferences) -> String {
        guard !preferences.files.isEmpty else { return "\(preferences.app) has no preference files." }
        let count = { (number: Int, word: String) in "\(number) \(word)\(number == 1 ? "" : "s")" }
        var lines = ["\(preferences.app): \(count(preferences.files.count, "file")), \(count(preferences.keyCount, "key")) (names and types only)"]
        for file in preferences.files {
            lines.append("  \(TerminalText.field(file.name))" + (file.binary ? " (binary, keys not listed)" : ""))
            lines += file.keys.map { "    \(TerminalText.field($0.name))  \($0.type)" }
        }
        return lines.joined(separator: "\n")
    }

    static func person(_ preferences: AppPreferences) -> [Block] {
        guard !preferences.files.isEmpty else { return DevicePersonView.receipt("\(preferences.app) has no preference files") }
        return preferences.files.flatMap { file -> [Block] in
            let header = Block.header(Header(.app, TerminalText.field(file.name), [file.binary ? "binary, keys not listed" : "\(file.keys.count) key\(file.keys.count == 1 ? "" : "s")"]))
            return file.keys.isEmpty ? [header] : [header, .fields(file.keys.map { Field(TerminalText.field($0.name), Table.Cell($0.type)) })]
        }
    }
}
