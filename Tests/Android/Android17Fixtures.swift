import Foundation

/// `AndroidAwakeState.readScript`'s output on an Android 17 (API 37) phone with a PIN, whose keyguard dump has `simSecure=` and no `secure=`.
enum Android17Fixtures {
    nonisolated static let awakeLocked = """
    maker=motorola
      mWakefulness=Awake
      mIsPowered=true
      mPlugType=2
      mScreenOffTimeoutSetting=60000
      mMaximumScreenOffTimeoutFromDeviceAdmin=9223372036854775807 (enforced=false)
      mStayOnWhilePluggedInSetting=15
      mIsPowered=true
      Display Power: state=ON
        showing=true
        occluded=false
        simSecure=false
      CredentialType: PIN

    """

    nonisolated static let awakeUnlocked = awakeLocked.replacingOccurrences(of: "showing=true", with: "showing=false")

    nonisolated static func awake(credential: String = "PIN", simSecure: Bool = false) -> String {
        awakeLocked
            .replacingOccurrences(of: "CredentialType: PIN", with: "CredentialType: \(credential)")
            .replacingOccurrences(of: "simSecure=false", with: "simSecure=\(simSecure)")
    }
}
