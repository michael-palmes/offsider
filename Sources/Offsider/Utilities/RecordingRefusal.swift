import Foundation
import OffsiderCore

extension RecordingMarker {
    /// Exit 8 when `command` would type `what` on camera; the caller holds the device lock, and a recording marks the device before it checks the holder.
    static func refuseTyping(
        _ what: String, command: String, on device: DeviceID, name: String? = nil, recordingLive: (DeviceLockKey) -> Bool = { RecordingMarker.isLive($0) },
        recorders: (DeviceLockKey) -> [Int32] = { RecordingMarker.pids($0) }
    ) throws {
        let key = DeviceLockKey(platform: device.platform, id: device.rawValue)
        guard recordingLive(key) else { return }
        let pids = recorders(key).map(String.init)
        let who = pids.isEmpty ? "" : ", pid \(pids.joined(separator: " and "))"
        throw CLIError(
            errorDescription: "A recording is running on \(name ?? device.rawValue) (record-video or stream-video\(who)), so \(command) will not type \(what) until it stops. Stop the recording, then retry. Nothing was typed.",
            reason: .deviceBusy,
            hint: pids.isEmpty ? "offsider session stop --device \(device.rawValue)" : "kill -INT \(pids.joined(separator: " "))"
        )
    }

    /// How long a recording told to stop has to save.
    static let stopWait: Duration = .seconds(10)

    /// Tells `key`'s recordings to stop and save, and waits; true when none is left, false when one still runs, nil when none was running.
    static func stopRecordings(_ key: DeviceLockKey, wait: Duration = stopWait) async -> (ended: Bool, pids: [Int32])? {
        guard isLive(key) else { return nil }
        let pids = RecordingMarker.pids(key)
        for pid in pids { _ = kill(pid, SIGINT) }
        let deadline = ContinuousClock.now + wait
        while isLive(key), !pids.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (!isLive(key), pids)
    }
}
