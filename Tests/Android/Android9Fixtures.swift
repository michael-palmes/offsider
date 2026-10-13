import Foundation
@testable import OffsiderAndroid

/// Display probe, status and package outputs captured from an Android 9 (API 28) emulator with the pixel_4 profile.
enum Android9Fixtures {
    /// Android 9 prints `Viewport:` without `INTERNAL`: once in the touch screen's section, then as the internal and external viewports.
    nonisolated static let portraitProbe = """
    Physical size: 1080x2280
    Physical density: 440
          Viewport: displayId=0, orientation=0, logicalFrame=[0, 0, 1080, 2280], physicalFrame=[0, 0, 1080, 2280], deviceSize=[1080, 2280]
              Viewport: displayId=0, orientation=0, uniqueId='', logicalFrame=[0, 0, 1080, 2280], physicalFrame=[0, 0, 1080, 2280], deviceSize=[1080, 2280]
              Viewport: displayId=0, orientation=0, uniqueId='', logicalFrame=[0, 0, 1080, 2280], physicalFrame=[0, 0, 1080, 2280], deviceSize=[1080, 2280]

    """

    /// Turned a quarter (`user_rotation` 1).
    nonisolated static let turnedProbe = """
    Physical size: 1080x2280
    Physical density: 440
          Viewport: displayId=0, orientation=1, logicalFrame=[0, 0, 2280, 1080], physicalFrame=[0, 0, 2280, 1080], deviceSize=[2280, 1080]
              Viewport: displayId=0, orientation=1, uniqueId='', logicalFrame=[0, 0, 2280, 1080], physicalFrame=[0, 0, 2280, 1080], deviceSize=[2280, 1080]
              Viewport: displayId=0, orientation=1, uniqueId='', logicalFrame=[0, 0, 2280, 1080], physicalFrame=[0, 0, 2280, 1080], deviceSize=[2280, 1080]

    """

    /// `dumpsys display`'s lines for the one panel; `cmd device_state` has no service on Android 9, so it prints nothing to stdout.
    nonisolated static let dumpsysDisplay = """
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:0", 1080 x 2280, modeId 1, defaultModeId 1, supportedModes [{id=1, width=1080, height=2280, fps=60.000004}], colorMode -1, supportedColorModes [-1], HdrCapabilities android.view.Display$HdrCapabilities@40f16308, density 440, 440.0 x 440.0 dpi, appVsyncOff 1000000, presDeadline 16666666, touch INTERNAL, rotation 0, type BUILT_IN, state ON, FLAG_DEFAULT_DISPLAY, FLAG_ROTATES_WITH_CONTENT, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS}
      Display 0:
        mPrimaryDisplayDevice=Built-in Screen

    """

    /// `AndroidAwakeState.readScript` with no lock credential set: Android 9's lock settings print no `CredentialType`.
    nonisolated static let awakeRead = """
    maker=unknown
      mWakefulness=Awake
      mIsPowered=true
      mPlugType=1
      mScreenOffTimeoutSetting=2147483647
      mMaximumScreenOffTimeoutFromDeviceAdmin=9223372036854775807 (enforced=false)
      mStayOnWhilePluggedInSetting=1
      mIsPowered=true
          showing=false
          occluded=false
          secure=false

    """

    /// `AndroidPermissionPlan.readScript`'s stdout with camera untouched (so unlisted), location granted and contacts user-fixed.
    nonisolated static let permissionRead = """
    28
    Packages:
      Package [com.example.app] (5c9b1cb):
        versionCode=1 minSdk=24 targetSdk=36
        declared permissions:
          com.example.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION: prot=signature, INSTALLED
        requested permissions:
          android.permission.CAMERA
          android.permission.INTERNET
          android.permission.POST_NOTIFICATIONS
          android.permission.ACCESS_FINE_LOCATION
          android.permission.READ_CONTACTS
          android.permission.SYSTEM_ALERT_WINDOW
          com.example.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
        install permissions:
          com.example.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION: granted=true
          android.permission.INTERNET: granted=true
        User 0: ceDataInode=115097 installed=true hidden=false suspended=false stopped=false notLaunched=false enabled=0 instant=false virtual=false
          gids=[3003]
          runtime permissions:
            android.permission.READ_CONTACTS: granted=false, flags=[ USER_SET|USER_FIXED ]
            android.permission.ACCESS_FINE_LOCATION: granted=true

    Package Changes:
      Sequence number=457

    """

    /// `pm list permissions -g -d`, trimmed to three groups.
    nonisolated static let dangerousPermissions = """
    Dangerous Permissions:

    group:android.permission-group.CONTACTS
      permission:android.permission.WRITE_CONTACTS
      permission:android.permission.GET_ACCOUNTS
      permission:android.permission.READ_CONTACTS

    group:android.permission-group.CAMERA
      permission:android.permission.CAMERA

    group:android.permission-group.LOCATION
      permission:android.permission.ACCESS_FINE_LOCATION
      permission:android.permission.ACCESS_COARSE_LOCATION

    ungrouped:
      permission:com.example.provider.permission.READ_ONLY

    """

    /// `AndroidDisplayStatus.scriptWithProbe`'s stdout on Android 9.
    nonisolated static func status(probe: String = portraitProbe) -> String {
        let separator = AndroidDisplayStatus.separator + "\n"
        return separator + separator + dumpsysDisplay + separator + probe
    }
}
