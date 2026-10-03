import Foundation
@testable import OffsiderAndroid

/// `cmd device_state` and `dumpsys display` outputs; the Pixel 9 ones are captures from Offsider_E2E_Pixel_9 (API 36).
enum FoldableFixtures {
    nonisolated static let pixel9PrintStates = """
    Supported states: [
      DeviceState{identifier=0, name='DEFAULT', app_accessible=true, cancel_when_requester_not_on_top=false},
    ]

    """

    nonisolated static let pixel9State = """
    Committed state: DeviceState{identifier=0, name='DEFAULT', app_accessible=true, cancel_when_requester_not_on_top=false}

    """

    /// Trimmed to the lines the parser reads and a few around them.
    nonisolated static let pixel9Dumpsys = """
    DISPLAY MANAGER (dumpsys display)
    Display Devices: size=1
    -----------------------
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4619827259835644672", 1080 x 2424, modeId 1, renderFrameRate 60.000004, hasArrSupport false, frameRateCategoryRate FrameRateCategoryRate {normal=60.0, high=90.0}, supportedRefreshRates [60.000004], defaultModeId 1, userPreferredModeId -1, supportedModes [{id=1, width=1080, height=2424, fps=60.000004, vsync=60.000004, synthetic=false, alternativeRefreshRates=[], supportedHdrTypes=[]}], colorMode 0, supportedColorModes [0], hdrCapabilities HdrCapabilities{mSupportedHdrTypes=[], mMaxLuminance=500.0, mMaxAverageLuminance=500.0, mMinLuminance=0.0}, isForceSdr false, allmSupported false, gameContentTypeSupported false, density 420, 420.0 x 420.0 dpi, appVsyncOff 1000000, presDeadline 16666666, touch INTERNAL, rotation 0, type INTERNAL, address {port=0, model=0x401cec6a7a2b7b}, deviceProductInfo DeviceProductInfo{name=EMU_display_0, manufacturerPnpId=GGL, productId=1, modelYear=null, manufactureDate=ManufactureDate{week=27, year=2006}, connectionToSinkType=1}, state ON, committedState ON, frameRateOverride , brightnessMinimum 0.035433073, brightnessMaximum 1.0, brightnessDefault 0.39763778, brightnessDim 0.05, hdrSdrRatio NaN, FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY, FLAG_ROTATES_WITH_CONTENT, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_TRUSTED, installOrientation 0, displayShape DisplayShape{ spec=-233499163 displayWidth=1080 displayHeight=2424 physicalPixelDisplaySizeRatio=1.0 rotation=0 offsetX=0 offsetY=0 scale=1.0}}
        mAdapter=LocalDisplayAdapter
        mUniqueId=local:4619827259835644672
        mPhysicalDisplayId=4619827259835644672
      mBootCompleted=true

      Logical Displays: size=1
      Display 0:
        mDisplayId=0
        mPrimaryDisplayDevice=Built-in Screen(local:4619827259835644672)
        mIsEnabled=true

    """

    nonisolated static let pixel9Geometry = """
    Physical size: 1080x2424
    Physical density: 420
      Viewport INTERNAL: displayId=0, uniqueId=local:4619827259835644672, port=Optional(0), orientation=0, logicalFrame=[0, 0, 1080, 2424], isActive=[1]
    """

    nonisolated static let coverId = "4619827259835644672"
    nonisolated static let innerId = "4619827259835644673"

    /// Constructed; replace with a capture from Offsider_E2E_Pixel_9_Pro_Fold.
    nonisolated static let foldPrintStates = """
    Supported states: [
      DeviceState{identifier=0, name='CLOSED', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=1, name='HALF_OPENED', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=2, name='OPENED', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=3, name='REAR_DISPLAY_STATE', app_accessible=true, cancel_when_requester_not_on_top=true},
      DeviceState{identifier=4, name='CONCURRENT_INNER_DEFAULT', app_accessible=true, cancel_when_requester_not_on_top=true},
    ]

    """

    /// Constructed; replace with a capture from Offsider_E2E_Pixel_9_Pro_Fold.
    nonisolated static func foldState(committed: Int, base: Int, override: Int?) -> String {
        let names = ["CLOSED", "HALF_OPENED", "OPENED", "REAR_DISPLAY_STATE", "CONCURRENT_INNER_DEFAULT"]
        func state(_ id: Int) -> String { "DeviceState{identifier=\(id), name='\(names[id])', app_accessible=true, cancel_when_requester_not_on_top=false}" }
        guard let override else { return "Committed state: \(state(committed))\n" }
        return """
        Committed state: \(state(committed))
        ----------------------
        Base state: \(state(base))
        Override state: \(state(override))

        """
    }

    /// Constructed from the Pixel 9 capture and the Pixel 9 Pro Fold profile; replace with a capture from Offsider_E2E_Pixel_9_Pro_Fold.
    nonisolated static func foldDumpsys(closed: Bool) -> String {
        """
        Display Devices: size=3
        -----------------------
          DisplayDeviceInfo{"Built-in Screen": uniqueId="local:\(coverId)", 1080 x 2424, modeId 1, density 390, 390.0 x 390.0 dpi, touch INTERNAL, rotation 0, type INTERNAL, state \(closed ? "ON" : "OFF"), committedState \(closed ? "ON" : "OFF"), FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY, installOrientation 0}
          DisplayDeviceInfo{"Built-in Screen": uniqueId="local:\(innerId)", 2076 x 2152, modeId 2, density 390, 390.0 x 390.0 dpi, touch INTERNAL, rotation 0, type INTERNAL, state \(closed ? "OFF" : "ON"), committedState \(closed ? "OFF" : "ON"), FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY, installOrientation 0}
          DisplayDeviceInfo{"ScreenRecorder": uniqueId="virtual:com.android.systemui,10123,ScreenRecorder,0", 1080 x 2424, modeId 3, density 390, 390.0 x 390.0 dpi, touch NONE, rotation 0, type VIRTUAL, state ON, committedState ON, installOrientation 0}

          Logical Displays: size=2
          Display 0:
            mDisplayId=0
            mPrimaryDisplayDevice=Built-in Screen(local:\(closed ? coverId : innerId))
          Display 2:
            mDisplayId=2
            mPrimaryDisplayDevice=ScreenRecorder(virtual:com.android.systemui,10123,ScreenRecorder,0)

        """
    }

    /// Constructed: the cover is portrait-natural, the inner display landscape-natural.
    nonisolated static func foldGeometry(closed: Bool, rotation: Int = 0) -> String {
        let natural = closed ? (1080, 2424) : (2076, 2152)
        let logical = rotation % 2 == 1 ? (natural.1, natural.0) : natural
        return """
        Physical size: \(natural.0)x\(natural.1)
        Physical density: 390
          Viewport INTERNAL: displayId=0, uniqueId=local:\(closed ? coverId : innerId), port=Optional(0), orientation=\(rotation), logicalFrame=[0, 0, \(logical.0), \(logical.1)], isActive=[1]
        """
    }

    /// What `AndroidDisplayStatus.script` prints: the three outputs between `echo`ed separators.
    nonisolated static func status(_ states: String, _ reading: String, _ dumpsys: String) -> String {
        [states, reading, dumpsys].joined(separator: "\(AndroidDisplayStatus.separator)\n")
    }
}
