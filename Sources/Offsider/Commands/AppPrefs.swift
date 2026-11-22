import ArgumentParser
import Foundation
import OffsiderCore

struct AppPrefsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefs",
        abstract: "List an app's preference and AsyncStorage key names, never their values.",
        discussion: """
        Android only. Lists each file in the app's shared_prefs folder with its key names and types, then the key names in \
        its React Native AsyncStorage database (RKStorage, or AsyncStorage for the library's Room storage). Values never \
        leave the device: its own `grep -o` prints only each preference key's opening tag, the database is read a page at a \
        time and the device prints only its schema page and key index pages, never a row, and no option asks for a value, \
        a length or a hash. It needs a debuggable build, as `run-as` does; a release build exits 1 with not_debuggable. An \
        active evidence run gets one manifest line with the key count, and nothing goes in the tree cache. A key name \
        shaped like a token is masked. A database that could not be read is named with one word (`unread` in --json) and \
        the preference files still print. DataStore, MMKV and other stores are not read.

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
        try AppManagementSupport.requireAndroid(deviceOption.id, command: "app prefs")
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
        recorder.update(token) { $0.entries = preferences.keyCount + (preferences.asyncStorage?.keys.count ?? 0) }
        let text = json ? AppManagementReport.preferences(preferences, on: route.device) : Self.lines(preferences)
        DevicePersonView.emit(text, json: json, person: Self.person(preferences), notices: Self.notices(preferences, on: route.device), console: .current)
    }

    static func count(_ number: Int, _ word: String) -> String { "\(number) \(word)\(number == 1 ? "" : "s")" }

    static func lines(_ preferences: AppPreferences) -> String {
        let storage = preferences.asyncStorage
        guard !preferences.files.isEmpty || storage != nil else { return "\(preferences.app) has no preference files." }
        var totals = [count(preferences.files.count, "file"), count(preferences.keyCount, "key")]
        if let storage, storage.unread == nil { totals.append(count(storage.keys.count, "AsyncStorage key")) }
        var lines = ["\(preferences.app): \(totals.joined(separator: ", ")) (names and types only)"]
        for file in preferences.files {
            lines.append("  \(TerminalText.field(file.name))" + (file.binary ? " (binary, keys not listed)" : ""))
            lines += file.keys.map { "    \(TerminalText.field($0.name))  \($0.type)" }
        }
        if let storage {
            lines.append("  AsyncStorage (\(storage.database))  \(summary(storage))")
            lines += storage.keys.map { "    \(TerminalText.field($0))" }
        }
        return lines.joined(separator: "\n")
    }

    static func summary(_ storage: AppKeyStore) -> String {
        storage.unread.map { "not read (\($0.rawValue))" } ?? count(storage.keys.count, "key")
    }

    static func person(_ preferences: AppPreferences) -> [Block] {
        guard !preferences.files.isEmpty || preferences.asyncStorage != nil else { return DevicePersonView.receipt("\(preferences.app) has no preference files") }
        var blocks = preferences.files.flatMap { file -> [Block] in
            let header = Block.header(Header(.app, TerminalText.field(file.name), [file.binary ? "binary, keys not listed" : count(file.keys.count, "key")]))
            return file.keys.isEmpty ? [header] : [header, .fields(file.keys.map { Field(TerminalText.field($0.name), Table.Cell($0.type)) })]
        }
        if let storage = preferences.asyncStorage {
            blocks.append(.header(Header(.app, "AsyncStorage (\(storage.database))", [summary(storage)])))
            if !storage.keys.isEmpty { blocks.append(.fields(storage.keys.map { Field(TerminalText.field($0), Table.Cell("key")) })) }
        }
        return blocks
    }

    /// Why a database was left unread, and what to do about it where there is something to do.
    static func notices(_ preferences: AppPreferences, on device: DeviceID) -> [Notice] {
        guard let storage = preferences.asyncStorage else { return [] }
        var notices: [Notice] = []
        if let other = storage.other {
            notices.append(.note("\(preferences.app) also has \(other), which was not read: these are \(storage.database)'s keys"))
        }
        let stop = "offsider app stop --app \(preferences.app) --device \(device.rawValue)"
        switch storage.unread {
        case nil: break
        case .changing: notices.append(.warning("\(storage.database) changed twice while it was read, so its keys are not listed. Stop the app, then run this again", try: stop))
        case .unfinished: notices.append(.warning("\(storage.database) has a write the app did not finish, so its keys are not listed. Run this again; if it repeats, open the app once"))
        case .utf16: notices.append(.warning("\(storage.database) stores text as UTF-16, which is not read, so its keys are not listed"))
        case .schema: notices.append(.warning("\(storage.database) is not laid out as AsyncStorage's own database, so its keys are not listed"))
        case .large: notices.append(.warning("\(storage.database) is too large to list, so its keys are not listed"))
        case .format: notices.append(.warning("\(storage.database) is not a SQLite database Offsider can read (it may be encrypted), so its keys are not listed"))
        case .corrupt: notices.append(.warning("\(storage.database) has a page that does not add up, so its keys are not listed"))
        case .failed: notices.append(.warning("\(device.rawValue) did not answer while \(storage.database) was read, so its keys are not listed. Run this again"))
        }
        if storage.cut > 0 {
            notices.append(.note("\(count(storage.cut, "key name")) too long to read whole, shown cut short"))
        }
        return notices
    }
}
