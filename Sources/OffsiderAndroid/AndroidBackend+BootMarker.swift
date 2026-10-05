import Darwin
import Foundation
import OffsiderCore

extension AndroidBackend: BootMarking {
    /// The emulator process's start time from its discovery file's pid, so a restarted emulator or a reused serial reads as a new boot; nil for a phone.
    public func bootMarker(for id: DeviceID) async -> String? {
        guard case .androidSerial(let port) = DeviceIDClassifier.classify(id.rawValue),
              let discovery = EmulatorDiscovery.live(host: host).first(where: { $0.consolePort == port }) else {
            return nil
        }
        guard let start = ProcessStartTime.of(discovery.pid) else { return nil }
        return "emulator \(start.seconds).\(String(format: "%06d", start.microseconds))"
    }
}
