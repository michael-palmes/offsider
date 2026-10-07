import Foundation

/// Meta keys a physical Android phone takes as system shortcuts (Meta+M opened Maps on a Samsung foldable).
public enum SystemKeyGuard {
    /// Left and right GUI: Command on iOS, Meta on Android.
    public static let metaUsages: Set<Int> = [227, 231]
    public static let allowFlag = "--allow-system-keys"

    /// Why `keys` are refused on `device` before anything is sent; nil when they may go.
    public static func refusal(keys: [Int], on device: DeviceID, allowed: Bool) -> String? {
        guard !allowed, device.isPhysicalAndroidDevice, let meta = keys.first(where: metaUsages.contains) else { return nil }
        return "Refused key \(meta) (Meta) on \(device.rawValue): an Android phone takes Meta combinations as system shortcuts, "
            + "which can open other apps. Nothing was sent. Control (224) selects all, as in key-combo --modifiers 224 --key 4; "
            + "pass \(allowFlag) to send Meta anyway."
    }
}
