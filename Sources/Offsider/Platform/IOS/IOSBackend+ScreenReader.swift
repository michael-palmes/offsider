import Foundation
import OffsiderCore

extension IOSBackend: ScreenReaderControlling {
    func screenReader(on id: DeviceID) async throws -> Bool {
        try await SimulatorScreenReaders.live(udid: id.rawValue).setting().enabled
    }

    func setScreenReader(_ enabled: Bool, on id: DeviceID) async throws -> ScreenReaderChange {
        try await SimulatorScreenReaders.live(udid: id.rawValue).set(enabled, store: ScreenReaderRecordStore.privateStore(create: enabled))
    }
}

extension SimulatorScreenReaders {
    /// `xcrun`'s stdout, or an error quoting its first stderr line.
    static func xcrun(timeout: TimeInterval = 30) -> @Sendable ([String]) async throws -> String {
        { arguments in
            let result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: arguments, timeout: timeout)
            guard result.status == 0 else {
                let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(result.status)"
                throw ScreenReaderError("xcrun \(arguments.prefix(2).joined(separator: " ")) failed: \(detail)")
            }
            return result.stdout
        }
    }

    static func live(udid: String, timeout: TimeInterval = 30) -> SimulatorScreenReader {
        SimulatorScreenReader(udid: udid, run: xcrun(timeout: timeout))
    }

    /// The simulators with a recorded reader, `device` alone when it is named; nothing is sent to them.
    static func recorded(device: String?) -> [String] {
        let named = device?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (ScreenReaderRecordStore.privateStore(create: false)?.all() ?? []).map(\.udid).filter { udid in named.map { udid.caseInsensitiveCompare($0) == .orderedSame } ?? true }
    }

    /// Every recorded reader turned off, on `device` or on all simulators; a device that is no simulator has none.
    static func resetRecorded(device: String?) async -> ScreenReaderResetOutcome {
        await resetRecorded(store: ScreenReaderRecordStore.privateStore(create: false), udid: device, run: xcrun())
    }
}
