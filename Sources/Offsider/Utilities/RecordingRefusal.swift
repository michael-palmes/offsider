import Foundation
import OffsiderCore

extension RecordingMarker {
    /// Exit 8 when `command` would type `what` on camera; the caller holds the device lock, and a recording marks the device before it checks the holder.
    static func refuseTyping(
        _ what: String, command: String, on device: DeviceID, name: String? = nil, recordingLive: (DeviceLockKey) -> Bool = { RecordingMarker.isLive($0) }
    ) throws {
        guard recordingLive(DeviceLockKey(platform: device.platform, id: device.rawValue)) else { return }
        throw CLIError(
            errorDescription: "A recording is running on \(name ?? device.rawValue) (record-video or stream-video), so \(command) will not type \(what) until it stops. Stop the recording, then retry. Nothing was typed.",
            reason: .deviceBusy
        )
    }
}
