import Foundation

/// Where a command's device came from.
enum DeviceSource: String, Sendable {
    case option
    case environment
    /// Chosen from the terminal picker, which offers only simulators and emulators.
    case picker
}

/// `OFFSIDER_DEVICE`, the device a command uses when `--device` is absent; a test binds its own value.
enum DeviceDefault {
    static let environmentKey = "OFFSIDER_DEVICE"
    static let missingMessage = "Missing --device <id>. Pass --device, or set OFFSIDER_DEVICE; run offsider list-devices to see IDs."

    @TaskLocal static var environment: @Sendable () -> String? = { ProcessInfo.processInfo.environment[environmentKey] }

    /// `--device` wins; a blank `OFFSIDER_DEVICE` counts as unset.
    static func resolve(explicit: String?, environment: String?) -> (id: String, source: DeviceSource)? {
        if let explicit { return (explicit, .option) }
        guard let value = environment?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return (value, .environment)
    }

    /// The device a person chose from the picker when the command named none; set once, before the command parses again.
    nonisolated(unsafe) static var picked: String?

    static func resolve(explicit: String?) -> (id: String, source: DeviceSource)? {
        let resolved = resolve(explicit: explicit, environment: environment()) ?? picked.map { ($0, DeviceSource.picker) }
        if let resolved { record(resolved.id, source: resolved.source) }
        return resolved
    }

    /// Where `id` last came from in this process, so the router can insist that a physical device is named with `--device`.
    static func lastSource(for id: String) -> DeviceSource? {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }
        return sources[id.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    static func record(_ id: String, source: DeviceSource) {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }
        sources[id.trimmingCharacters(in: .whitespacesAndNewlines)] = source
    }

    private static let sourcesLock = NSLock()
    nonisolated(unsafe) private static var sources: [String: DeviceSource] = [:]
}
