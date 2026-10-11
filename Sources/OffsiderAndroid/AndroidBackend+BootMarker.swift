import Foundation
import OffsiderCore

extension AndroidBackend: BootMarking {
    /// The emulator process's start time from its discovery file's pid, so a restarted emulator or a reused serial reads as a new boot; nil for a phone.
    public func bootMarker(for id: DeviceID) async -> String? {
        Self.emulatorDiscovery(serial: id.rawValue, host: host).flatMap { Self.bootMarker(of: $0, host: host) }
    }

    /// The AVD name of the emulator on this serial, from its discovery file alone; nil for a phone or an unknown serial.
    public nonisolated static func emulatorAVD(serial: String, host: AndroidHost) -> String? {
        emulatorDiscovery(serial: serial, host: host)?.avdID
    }

    private nonisolated static func emulatorDiscovery(serial: String, host: AndroidHost) -> EmulatorDiscovery? {
        guard case .androidSerial(let port) = DeviceIDClassifier.classify(serial) else { return nil }
        return EmulatorDiscovery.live(host: host).first { $0.consolePort == port }
    }

    /// The boot marker of the running emulator of this AVD, from its discovery file alone; nil when none runs, or for a phone serial.
    public nonisolated static func emulatorBootMarker(avd: String, host: AndroidHost) -> String? {
        EmulatorDiscovery.live(host: host).first { $0.avdID == avd }.flatMap { bootMarker(of: $0, host: host) }
    }

    /// `emulator <seconds>.<microseconds>` of the emulator process's start.
    private nonisolated static func bootMarker(of discovery: EmulatorDiscovery, host: AndroidHost) -> String? {
        guard let start = host.processStartTime(discovery.pid) else { return nil }
        let microseconds = Int64((start.timeIntervalSince1970 * 1_000_000).rounded())
        return "emulator \(microseconds / 1_000_000).\(String(format: "%06d", microseconds % 1_000_000))"
    }
}
