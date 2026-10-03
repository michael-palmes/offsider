import Foundation
@testable import OffsiderAndroid

/// `cmd device_state`, `dumpsys display` and display probe outputs, captured from Offsider_E2E_Pixel_9 and Offsider_E2E_Pixel_9_Pro_Fold (API 36).
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

    nonisolated static let pixel9Id = "4619827259835644672"
    nonisolated static let innerId = "4619827259835644672"
    nonisolated static let coverId = "4619827551948147201"

    nonisolated static let foldPrintStates = """
    Supported states: [
      DeviceState{identifier=0, name='CLOSED', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=1, name='HALF_OPENED', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=2, name='OPENED', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=3, name='REAR_DISPLAY_MODE', app_accessible=true, cancel_when_requester_not_on_top=false},
    ]
    """

    nonisolated static let foldStateOpen = """
    Committed state: DeviceState{identifier=2, name='OPENED', app_accessible=true, cancel_when_requester_not_on_top=false}
    """

    nonisolated static let foldStateClosed = """
    Committed state: DeviceState{identifier=0, name='CLOSED', app_accessible=true, cancel_when_requester_not_on_top=false}
    """

    /// `cmd device_state state 0` while the hinge was open.
    nonisolated static let foldStateClosedOverride = """
    Committed state: DeviceState{identifier=0, name='CLOSED', app_accessible=true, cancel_when_requester_not_on_top=false}
    ----------------------
    Base state: DeviceState{identifier=2, name='OPENED', app_accessible=true, cancel_when_requester_not_on_top=false}
    Override state: DeviceState{identifier=0, name='CLOSED', app_accessible=true, cancel_when_requester_not_on_top=false}
    """

    /// The capture's format for any committed, base and override states.
    nonisolated static func foldState(committed: Int, base: Int, override: Int?) -> String {
        let lines = foldPrintStates.split(separator: "\n").filter { $0.contains("DeviceState{") }
        func state(_ id: Int) -> String {
            String(lines.first { $0.contains("identifier=\(id),") }!.trimmingCharacters(in: .whitespaces).dropLast())
        }
        guard let override else { return "Committed state: \(state(committed))\n" }
        return "Committed state: \(state(committed))\n----------------------\nBase state: \(state(base))\nOverride state: \(state(override))\n"
    }

    /// `AndroidDisplayList.command`; the logical display the other panel backs is disabled but still listed.
    nonisolated static let foldDumpsysOpen = """
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4619827259835644672", 2076 x 2152, modeId 1, renderFrameRate 60.000004, hasArrSupport false, frameRateCategoryRate FrameRateCategoryRate {normal=60.0, high=90.0}, supportedRefreshRates [60.000004], defaultModeId 1, userPreferredModeId -1, supportedModes [{id=1, width=2076, height=2152, fps=60.000004, vsync=60.000004, synthetic=false, alternativeRefreshRates=[], supportedHdrTypes=[]}], colorMode 0, supportedColorModes [0], hdrCapabilities HdrCapabilities{mSupportedHdrTypes=[], mMaxLuminance=500.0, mMaxAverageLuminance=500.0, mMinLuminance=0.0}, isForceSdr false, allmSupported false, gameContentTypeSupported false, density 390, 390.0 x 390.0 dpi, appVsyncOff 1000000, presDeadline 16666666, cutout DisplayCutout{insets=Rect(0, 136 - 0, 0) waterfall=Insets{left=0, top=0, right=0, bottom=0} boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(1940, 0 - 2076, 136), Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0)]} cutoutPathParserInfo={CutoutPathParserInfo{displayWidth=2076 displayHeight=2152 physicalDisplayWidth=2076 physicalDisplayHeight=2152 density={2.4375} cutoutSpec={m 2027,80 a 39.5,39.5 0 0 0 -79,0 39.5,39.5 0 0 0 79,0 z @left} rotation={0} scale={1.0} physicalPixelDisplaySizeRatio={1.0}}} sideOverrides={ROTATION_0: top, ROTATION_90: top, ROTATION_180: bottom, ROTATION_270: bottom}}, touch INTERNAL, rotation 0, type INTERNAL, address {port=0, model=0x401cec6a7a2b7b}, deviceProductInfo DeviceProductInfo{name=EMU_display_0, manufacturerPnpId=GGL, productId=1, modelYear=null, manufactureDate=ManufactureDate{week=27, year=2006}, connectionToSinkType=1}, state ON, committedState ON, frameRateOverride , brightnessMinimum 0.035433073, brightnessMaximum 1.0, brightnessDefault 0.39763778, brightnessDim 0.05, hdrSdrRatio NaN, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=85, center=Point(85, 85)}, RoundedCorner{position=TopRight, radius=85, center=Point(1991, 85)}, RoundedCorner{position=BottomRight, radius=85, center=Point(1991, 2067)}, RoundedCorner{position=BottomLeft, radius=85, center=Point(85, 2067)}]}, FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY, FLAG_ROTATES_WITH_CONTENT, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_TRUSTED, installOrientation 0, displayShape DisplayShape{ spec=2000973833 displayWidth=2076 displayHeight=2152 physicalPixelDisplaySizeRatio=1.0 rotation=0 offsetX=0 offsetY=0 scale=1.0}}
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4619827551948147201", 1080 x 2424, modeId 2, renderFrameRate 53.333332, hasArrSupport false, frameRateCategoryRate FrameRateCategoryRate {normal=60.0, high=90.0}, supportedRefreshRates [160.0], defaultModeId 2, userPreferredModeId -1, supportedModes [{id=2, width=1080, height=2424, fps=160.0, vsync=160.0, synthetic=false, alternativeRefreshRates=[], supportedHdrTypes=[]}], colorMode 0, supportedColorModes [0], hdrCapabilities HdrCapabilities{mSupportedHdrTypes=[], mMaxLuminance=500.0, mMaxAverageLuminance=500.0, mMinLuminance=0.0}, isForceSdr false, allmSupported false, gameContentTypeSupported false, density 390, 390.0 x 390.0 dpi, appVsyncOff 2000000, presDeadline 6250000, cutout DisplayCutout{insets=Rect(0, 152 - 0, 0) waterfall=Insets{left=0, top=0, right=0, bottom=0} boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(484, 20 - 596, 152), Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0)]} cutoutPathParserInfo={CutoutPathParserInfo{displayWidth=1080 displayHeight=2424 physicalDisplayWidth=1080 physicalDisplayHeight=2424 density={2.4375} cutoutSpec={m 581.5,86 a 41.5,41.5 0 0 0 -83,0 41.5,41.5 0 0 0 83,0 z @left} rotation={0} scale={1.0} physicalPixelDisplaySizeRatio={1.0}}} sideOverrides={}}, touch INTERNAL, rotation 0, type INTERNAL, address {port=1, model=0x401cecae7d6e8a}, deviceProductInfo DeviceProductInfo{name=EMU_display_1, manufacturerPnpId=GGL, productId=1, modelYear=null, manufactureDate=ManufactureDate{week=27, year=2006}, connectionToSinkType=1}, state OFF, committedState OFF, frameRateOverride , brightnessMinimum 0.0, brightnessMaximum 1.0, brightnessDefault 0.5, brightnessDim -1.0, hdrSdrRatio NaN, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=115, center=Point(115, 115)}, RoundedCorner{position=TopRight, radius=115, center=Point(965, 115)}, RoundedCorner{position=BottomRight, radius=115, center=Point(965, 2309)}, RoundedCorner{position=BottomLeft, radius=115, center=Point(115, 2309)}]}, FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY, FLAG_ROTATES_WITH_CONTENT, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_TRUSTED, installOrientation 0, displayShape DisplayShape{ spec=-233499163 displayWidth=1080 displayHeight=2424 physicalPixelDisplaySizeRatio=1.0 rotation=0 offsetX=0 offsetY=0 scale=1.0}}
      Display 0:
        mPrimaryDisplayDevice=Built-in Screen(local:4619827259835644672)
      Display 3:
        mPrimaryDisplayDevice=Built-in Screen(local:4619827551948147201)
    """

    nonisolated static let foldDumpsysClosed = """
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4619827259835644672", 2076 x 2152, modeId 1, renderFrameRate 60.000004, hasArrSupport false, frameRateCategoryRate FrameRateCategoryRate {normal=60.0, high=90.0}, supportedRefreshRates [60.000004], defaultModeId 1, userPreferredModeId -1, supportedModes [{id=1, width=2076, height=2152, fps=60.000004, vsync=60.000004, synthetic=false, alternativeRefreshRates=[], supportedHdrTypes=[]}], colorMode 0, supportedColorModes [0], hdrCapabilities HdrCapabilities{mSupportedHdrTypes=[], mMaxLuminance=500.0, mMaxAverageLuminance=500.0, mMinLuminance=0.0}, isForceSdr false, allmSupported false, gameContentTypeSupported false, density 390, 390.0 x 390.0 dpi, appVsyncOff 1000000, presDeadline 16666666, cutout DisplayCutout{insets=Rect(0, 136 - 0, 0) waterfall=Insets{left=0, top=0, right=0, bottom=0} boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(1940, 0 - 2076, 136), Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0)]} cutoutPathParserInfo={CutoutPathParserInfo{displayWidth=2076 displayHeight=2152 physicalDisplayWidth=2076 physicalDisplayHeight=2152 density={2.4375} cutoutSpec={m 2027,80 a 39.5,39.5 0 0 0 -79,0 39.5,39.5 0 0 0 79,0 z @left} rotation={0} scale={1.0} physicalPixelDisplaySizeRatio={1.0}}} sideOverrides={ROTATION_0: top, ROTATION_90: top, ROTATION_180: bottom, ROTATION_270: bottom}}, touch INTERNAL, rotation 0, type INTERNAL, address {port=0, model=0x401cec6a7a2b7b}, deviceProductInfo DeviceProductInfo{name=EMU_display_0, manufacturerPnpId=GGL, productId=1, modelYear=null, manufactureDate=ManufactureDate{week=27, year=2006}, connectionToSinkType=1}, state OFF, committedState OFF, frameRateOverride , brightnessMinimum 0.035433073, brightnessMaximum 1.0, brightnessDefault 0.39763778, brightnessDim 0.05, hdrSdrRatio NaN, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=85, center=Point(85, 85)}, RoundedCorner{position=TopRight, radius=85, center=Point(1991, 85)}, RoundedCorner{position=BottomRight, radius=85, center=Point(1991, 2067)}, RoundedCorner{position=BottomLeft, radius=85, center=Point(85, 2067)}]}, FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY, FLAG_ROTATES_WITH_CONTENT, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_TRUSTED, installOrientation 0, displayShape DisplayShape{ spec=2000973833 displayWidth=2076 displayHeight=2152 physicalPixelDisplaySizeRatio=1.0 rotation=0 offsetX=0 offsetY=0 scale=1.0}}
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4619827551948147201", 1080 x 2424, modeId 2, renderFrameRate 53.333332, hasArrSupport false, frameRateCategoryRate FrameRateCategoryRate {normal=60.0, high=90.0}, supportedRefreshRates [160.0], defaultModeId 2, userPreferredModeId -1, supportedModes [{id=2, width=1080, height=2424, fps=160.0, vsync=160.0, synthetic=false, alternativeRefreshRates=[], supportedHdrTypes=[]}], colorMode 0, supportedColorModes [0], hdrCapabilities HdrCapabilities{mSupportedHdrTypes=[], mMaxLuminance=500.0, mMaxAverageLuminance=500.0, mMinLuminance=0.0}, isForceSdr false, allmSupported false, gameContentTypeSupported false, density 390, 390.0 x 390.0 dpi, appVsyncOff 2000000, presDeadline 6250000, cutout DisplayCutout{insets=Rect(0, 152 - 0, 0) waterfall=Insets{left=0, top=0, right=0, bottom=0} boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(484, 20 - 596, 152), Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0)]} cutoutPathParserInfo={CutoutPathParserInfo{displayWidth=1080 displayHeight=2424 physicalDisplayWidth=1080 physicalDisplayHeight=2424 density={2.4375} cutoutSpec={m 581.5,86 a 41.5,41.5 0 0 0 -83,0 41.5,41.5 0 0 0 83,0 z @left} rotation={0} scale={1.0} physicalPixelDisplaySizeRatio={1.0}}} sideOverrides={}}, touch INTERNAL, rotation 0, type INTERNAL, address {port=1, model=0x401cecae7d6e8a}, deviceProductInfo DeviceProductInfo{name=EMU_display_1, manufacturerPnpId=GGL, productId=1, modelYear=null, manufactureDate=ManufactureDate{week=27, year=2006}, connectionToSinkType=1}, state ON, committedState ON, frameRateOverride , brightnessMinimum 0.0, brightnessMaximum 1.0, brightnessDefault 0.5, brightnessDim -1.0, hdrSdrRatio NaN, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=115, center=Point(115, 115)}, RoundedCorner{position=TopRight, radius=115, center=Point(965, 115)}, RoundedCorner{position=BottomRight, radius=115, center=Point(965, 2309)}, RoundedCorner{position=BottomLeft, radius=115, center=Point(115, 2309)}]}, FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY, FLAG_ROTATES_WITH_CONTENT, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_TRUSTED, installOrientation 0, displayShape DisplayShape{ spec=-233499163 displayWidth=1080 displayHeight=2424 physicalPixelDisplaySizeRatio=1.0 rotation=0 offsetX=0 offsetY=0 scale=1.0}}
      Display 0:
        mPrimaryDisplayDevice=Built-in Screen(local:4619827551948147201)
      Display 1:
        mPrimaryDisplayDevice=Built-in Screen(local:4619827259835644672)
    """

    nonisolated static func foldDumpsys(closed: Bool) -> String {
        closed ? foldDumpsysClosed : foldDumpsysOpen
    }

    /// `AndroidDisplayGeometry.probeScript`; the input dump lists display 0's viewport twice.
    nonisolated static let foldGeometryOpen = """
    Physical size: 2076x2152
    Physical density: 390
          Viewport INTERNAL: displayId=0, uniqueId=local:4619827259835644672, port=0, orientation=0, logicalFrame=[0, 0, 2076, 2152], physicalFrame=[0, 0, 2076, 2152], deviceSize=[2076, 2152], isActive=[1]
            Viewport INTERNAL: displayId=0, uniqueId=local:4619827259835644672, port=0, orientation=0, logicalFrame=[0, 0, 2076, 2152], physicalFrame=[0, 0, 2076, 2152], deviceSize=[2076, 2152], isActive=[1]
    """

    nonisolated static let foldGeometryClosed = """
    Physical size: 1080x2424
    Physical density: 390
          Viewport INTERNAL: displayId=0, uniqueId=local:4619827551948147201, port=1, orientation=0, logicalFrame=[0, 0, 1080, 2424], physicalFrame=[0, 0, 1080, 2424], deviceSize=[1080, 2424], isActive=[1]
          Viewport INTERNAL: displayId=0, uniqueId=local:4619827551948147201, port=1, orientation=0, logicalFrame=[0, 0, 1080, 2424], physicalFrame=[0, 0, 1080, 2424], deviceSize=[1080, 2424], isActive=[1]
            Viewport INTERNAL: displayId=0, uniqueId=local:4619827551948147201, port=1, orientation=0, logicalFrame=[0, 0, 1080, 2424], physicalFrame=[0, 0, 1080, 2424], deviceSize=[1080, 2424], isActive=[1]
    """

    /// Mid-unfold: display 0's viewport already names the inner panel, but `wm size` and its frame are still the cover's.
    nonisolated static let foldGeometryUnfolding = """
    Physical size: 1080x2424
    Physical density: 390
          Viewport INTERNAL: displayId=0, uniqueId=local:4619827259835644672, port=0, orientation=0, logicalFrame=[0, 0, 1080, 2424], physicalFrame=[559, 0, 1517, 2152], deviceSize=[2076, 2152], isActive=[0]
            Viewport INTERNAL: displayId=0, uniqueId=local:4619827259835644672, port=0, orientation=0, logicalFrame=[0, 0, 1080, 2424], physicalFrame=[559, 0, 1517, 2152], deviceSize=[2076, 2152], isActive=[0]
    """

    nonisolated static func foldGeometry(closed: Bool) -> String {
        closed ? foldGeometryClosed : foldGeometryOpen
    }

    /// What `AndroidDisplayStatus.script` prints: the three outputs between `echo`ed separators.
    nonisolated static func status(_ states: String, _ reading: String, _ dumpsys: String) -> String {
        [states, reading, dumpsys].joined(separator: "\(AndroidDisplayStatus.separator)\n")
    }
}
