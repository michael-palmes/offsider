import Foundation

/// Optional capability: the device's screen reader. A change Offsider made is recorded, so `session stop` undoes that and nothing else.
@MainActor
public protocol ScreenReaderControlling: DeviceBackend {
    /// `VoiceOver` or `TalkBack`.
    var screenReaderService: String { get }
    func screenReader(on id: DeviceID) async throws -> Bool
    /// Whether Offsider recorded turning it on for this device, so `session stop` turns it off.
    func screenReaderIsRecorded(on id: DeviceID) -> Bool
    func setScreenReader(_ enabled: Bool, on id: DeviceID) async throws -> ScreenReaderChange
}

public struct ScreenReaderChange: Equatable, Sendable {
    public var previous: Bool
    public var current: Bool
    /// True when Offsider turned it on, so `session stop` turns it off.
    public var resetBySessionStop: Bool

    public init(previous: Bool, current: Bool, resetBySessionStop: Bool) {
        self.previous = previous
        self.current = current
        self.resetBySessionStop = resetBySessionStop
    }
}

public struct ScreenReaderError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String
    public let reason: FailureReason
    public let hint: String?

    public init(_ message: String, reason: FailureReason = .commandFailed, hint: String? = nil) {
        self.message = message
        self.reason = reason
        self.hint = hint
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

extension ScreenReaderError: OffsiderFailure {
    public var failureMessage: String { message }
}

/// A screen reader Offsider turned on, kept until `screen-reader off`, `session stop` or `shutdown` turns it off. The setting outlives a reboot.
public struct ScreenReaderRecord: Equatable, Sendable {
    static let maximumBytes = 1_024

    /// The simulator's UDID, uppercased.
    public let udid: String
    /// VoiceOver's volume before Offsider set it to zero; nil when it was unset.
    public let volume: Double?

    public init(udid: String, volume: Double?) {
        self.udid = udid.uppercased()
        self.volume = volume
    }

    func encoded() -> Data {
        var object: [String: Any] = ["udid": udid]
        if let volume { object["volume"] = volume }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let udid = object["udid"] as? String, UUID(uuidString: udid) != nil else { return nil }
        self.init(udid: udid, volume: (object["volume"] as? NSNumber)?.doubleValue)
    }
}

/// One record per simulator under the private directory's `screen-reader/`.
public struct ScreenReaderRecordStore: Sendable {
    public static let directoryName = "screen-reader"

    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// The private directory's `screen-reader/`, made 0700 when `create`; nil when it is missing or not private.
    public static func privateStore(create: Bool, root: String = OffsiderPrivateDirectory.root) -> ScreenReaderRecordStore? {
        let directory = create ? try? OffsiderPrivateDirectory.ensureSubdirectory(directoryName, root: root) : (try? OffsiderPrivateDirectory.existingSubdirectory(directoryName, root: root)) ?? nil
        return directory.map(ScreenReaderRecordStore.init(directory:))
    }

    static func fileName(udid: String) -> String? {
        UUID(uuidString: udid).map { "ios-\($0.uuidString).json" }
    }

    /// The record for `udid`, or nil; a corrupt or foreign one is removed.
    public func load(udid: String) -> ScreenReaderRecord? {
        guard let name = Self.fileName(udid: udid), let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: ScreenReaderRecord.maximumBytes) else { return nil }
        guard let record = ScreenReaderRecord(data: data), Self.fileName(udid: record.udid) == name else {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return nil
        }
        return record
    }

    public func all() -> [ScreenReaderRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let udid = String(name.dropFirst(4).dropLast(5))
            guard Self.fileName(udid: udid) == name else {
                OffsiderPrivateDirectory.removeFile(named: name, in: directory)
                return nil
            }
            return load(udid: udid)
        }
    }

    public func save(_ record: ScreenReaderRecord) throws {
        guard let name = Self.fileName(udid: record.udid) else { throw ScreenReaderError("\(record.udid) is not a simulator UDID.") }
        try OffsiderPrivateDirectory.writeAtomically(record.encoded(), named: name, in: directory)
    }

    public func remove(udid: String) {
        guard let name = Self.fileName(udid: udid) else { return }
        OffsiderPrivateDirectory.removeFile(named: name, in: directory)
    }
}

/// VoiceOver's switch on an iOS simulator: the preference apps read. A simulator never starts VoiceOver itself, so nothing speaks and touches keep their meaning.
public struct SimulatorScreenReader: Sendable {
    public struct Setting: Equatable, Sendable {
        public var enabled: Bool
        public var volume: Double?

        public init(enabled: Bool, volume: Double?) {
            self.enabled = enabled
            self.volume = volume
        }
    }

    public static let service = "VoiceOver"
    public static let domain = "com.apple.Accessibility"
    public static let enabledKey = "VoiceOverTouchEnabled"
    public static let volumeKey = "VoiceOverTouchVolume"
    public static let notification = "com.apple.accessibility.cache.vot"
    static let polls = 10
    static let pollInterval: Duration = .milliseconds(200)

    public let udid: String
    /// Runs `xcrun` with these arguments and returns its stdout; a non-zero exit throws.
    let run: @Sendable ([String]) async throws -> String
    var pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    public init(udid: String, run: @escaping @Sendable ([String]) async throws -> String) {
        self.udid = udid
        self.run = run
    }

    static func readArguments(udid: String) -> [String] {
        ["simctl", "spawn", udid, "defaults", "export", domain, "-"]
    }

    static func writeArguments(udid: String, key: String, value: [String]) -> [String] {
        ["simctl", "spawn", udid, "defaults", "write", domain, key] + value
    }

    static func deleteArguments(udid: String, key: String) -> [String] {
        ["simctl", "spawn", udid, "defaults", "delete", domain, key]
    }

    static func postArguments(udid: String) -> [String] {
        ["simctl", "spawn", udid, "notifyutil", "-p", notification]
    }

    /// The two keys from `defaults export`'s property list; nil when it is not one.
    public static func parse(_ export: String) -> Setting? {
        guard let object = unsafe (try? PropertyListSerialization.propertyList(from: Data(export.utf8), format: nil)) as? [String: Any] else { return nil }
        return Setting(enabled: (object[enabledKey] as? NSNumber)?.boolValue ?? false, volume: (object[volumeKey] as? NSNumber)?.doubleValue)
    }

    public func setting() async throws -> Setting {
        guard let setting = Self.parse(try await run(Self.readArguments(udid: udid))) else {
            throw ScreenReaderError("Simulator \(udid) did not say whether VoiceOver is on.")
        }
        return setting
    }

    /// The record comes first, so a reader is never turned on without one; a change that fails is undone, and the record goes once the reader reads off.
    public func set(_ enabled: Bool, store: ScreenReaderRecordStore?) async throws -> ScreenReaderChange {
        let before = try await setting()
        let earlier = store?.load(udid: udid)
        guard enabled else {
            guard before.enabled || earlier != nil else { return ScreenReaderChange(previous: false, current: false, resetBySessionStop: false) }
            guard try await turnOff(restoring: earlier) else {
                throw ScreenReaderError("Simulator \(udid) did not turn VoiceOver off in time. Run the command again.")
            }
            store?.remove(udid: udid)
            return ScreenReaderChange(previous: before.enabled, current: false, resetBySessionStop: false)
        }
        guard !before.enabled else { return ScreenReaderChange(previous: true, current: true, resetBySessionStop: earlier != nil) }
        guard let store else {
            throw ScreenReaderError("Offsider has no private folder to record the screen reader in, so it left it off.")
        }
        let record = earlier ?? ScreenReaderRecord(udid: udid, volume: before.volume)
        try store.save(record)
        do {
            if before.volume != 0 { _ = try await run(Self.writeArguments(udid: udid, key: Self.volumeKey, value: ["-float", "0"])) }
            _ = try await run(Self.writeArguments(udid: udid, key: Self.enabledKey, value: ["-bool", "true"]))
            _ = try await run(Self.postArguments(udid: udid))
            guard try await reaches(true) else {
                throw ScreenReaderError("Simulator \(udid) did not turn VoiceOver on in time.")
            }
            if store.load(udid: udid) == nil { try store.save(record) }
        } catch {
            if (try? await turnOff(restoring: record)) == true { store.remove(udid: udid) }
            throw error
        }
        return ScreenReaderChange(previous: false, current: true, resetBySessionStop: true)
    }

    /// Off, with the volume Offsider replaced put back; true once the setting reads off.
    func turnOff(restoring record: ScreenReaderRecord?) async throws -> Bool {
        _ = try await run(Self.writeArguments(udid: udid, key: Self.enabledKey, value: ["-bool", "false"]))
        if let record {
            if let volume = record.volume {
                _ = try await run(Self.writeArguments(udid: udid, key: Self.volumeKey, value: ["-float", String(volume)]))
            } else {
                _ = try? await run(Self.deleteArguments(udid: udid, key: Self.volumeKey))
            }
        }
        _ = try await run(Self.postArguments(udid: udid))
        return try await reaches(false)
    }

    private func reaches(_ enabled: Bool) async throws -> Bool {
        for attempt in 0..<Self.polls {
            if try await setting().enabled == enabled { return true }
            if attempt < Self.polls - 1 { await pause(Self.pollInterval) }
        }
        return false
    }
}

/// What `session stop` did with the recorded readers.
public struct ScreenReaderResetOutcome: Equatable, Sendable {
    public var reset: [String] = []
    /// Still recorded: the simulator would not take the change, or was between states.
    public var failed: [String] = []

    public init(reset: [String] = [], failed: [String] = []) {
        self.reset = reset
        self.failed = failed
    }
}

public enum SimulatorScreenReaders {
    public struct Simulator: Equatable, Sendable {
        public let state: String
        public let dataPath: String?

        public init(state: String, dataPath: String?) {
            self.state = state
            self.dataPath = dataPath
        }
    }

    public static let listArguments = ["simctl", "list", "devices", "-j"]

    /// `simctl list devices -j` as uppercased UDID to state and data folder; nil when it is not that.
    public static func parseDevices(_ json: String) -> [String: Simulator]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let runtimes = object["devices"] as? [String: Any] else { return nil }
        var found: [String: Simulator] = [:]
        for case let devices as [[String: Any]] in runtimes.values {
            for device in devices {
                guard let udid = device["udid"] as? String, let state = device["state"] as? String else { continue }
                found[udid.uppercased()] = Simulator(state: state, dataPath: device["dataPath"] as? String)
            }
        }
        return found
    }

    /// Turns off each recorded reader, on `udid` or everywhere: a booted simulator is asked, a shut-down one has its preference file changed, a deleted one loses its record.
    public static func resetRecorded(store: ScreenReaderRecordStore?, udid: String?, run: @escaping @Sendable ([String]) async throws -> String) async -> ScreenReaderResetOutcome {
        var outcome = ScreenReaderResetOutcome()
        guard let store else { return outcome }
        let records = store.all().filter { record in udid.map { record.udid.caseInsensitiveCompare($0.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } ?? true }
        guard !records.isEmpty else { return outcome }
        guard let listed = try? await run(listArguments), let simulators = parseDevices(listed) else {
            outcome.failed = records.map(\.udid)
            return outcome
        }
        for record in records {
            guard let simulator = simulators[record.udid] else {
                store.remove(udid: record.udid)
                continue
            }
            let done: Bool
            switch simulator.state {
            case "Booted":
                done = (try? await SimulatorScreenReader(udid: record.udid, run: run).turnOff(restoring: record)) == true
            case "Shutdown":
                done = simulator.dataPath.map { turnOffOnDisk(record, dataPath: $0) } ?? false
            default:
                done = false
            }
            if done {
                store.remove(udid: record.udid)
                outcome.reset.append(record.udid)
            } else {
                outcome.failed.append(record.udid)
            }
        }
        return outcome
    }

    static func preferencesPath(dataPath: String) -> String {
        dataPath + "/Library/Preferences/" + SimulatorScreenReader.domain + ".plist"
    }

    /// A shut-down simulator's setting, changed in its preference file; true when the file now reads off, or was never there.
    static func turnOffOnDisk(_ record: ScreenReaderRecord, dataPath: String) -> Bool {
        let path = preferencesPath(dataPath: dataPath)
        guard FileManager.default.fileExists(atPath: path) else { return true }
        guard var preferences = UntrustedRead.propertyList(atPath: path) else { return false }
        preferences[SimulatorScreenReader.enabledKey] = false
        preferences[SimulatorScreenReader.volumeKey] = record.volume
        guard let data = try? PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0) else { return false }
        let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
        guard (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return false }
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
        return true
    }
}

extension DeviceStateReport {
    /// `screen-reader`'s JSON: `action` is `show`, `on` or `off`, and `previous` is null for a read.
    public static func screenReader(_ action: String, current: Bool, previous: Bool?, service: String, resetBySessionStop: Bool, on device: DeviceID) -> String {
        let word: (Bool) -> OrderedJSON = { .string($0 ? "on" : "off") }
        return OrderedJSON.object(header(action, device: device) + [
            ("screenReader", word(current)),
            ("previous", .optional(previous, word)),
            ("service", .string(service)),
            ("resetBySessionStop", .bool(resetBySessionStop)),
        ]).rendered(compact: true)
    }
}
