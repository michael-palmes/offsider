import Foundation
@testable import OffsiderAndroid

/// `cmd device_state`, `dumpsys display` and display probe outputs, captured from a Galaxy Z Fold (One UI 6, API 34) over USB.
enum GalaxyFoldFixtures {
    nonisolated static let innerId = "4600000000000000001"
    nonisolated static let coverId = "4600000000000000002"

    nonisolated static let printStates = """
    Supported states: [
      DeviceState{identifier=0, name='CLOSE', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=1, name='TENT', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=2, name='HALF_FOLDED', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=3, name='OPEN', app_accessible=true, cancel_when_requester_not_on_top=false},
      DeviceState{identifier=4, name='DUAL', app_accessible=true, cancel_when_requester_not_on_top=true},
      DeviceState{identifier=5, name='REAR_DUAL', app_accessible=true, cancel_when_requester_not_on_top=false},
    ]

    """

    nonisolated static func state(closed: Bool) -> String {
        closed ? "Committed state: DeviceState{identifier=0, name='CLOSE', app_accessible=true, cancel_when_requester_not_on_top=false}\n" : "Committed state: DeviceState{identifier=3, name='OPEN', app_accessible=true, cancel_when_requester_not_on_top=false}\n"
    }

    /// `AndroidDisplayList.command`: One UI names display 0's panel without its `uniqueId`, and only the active panel is on.
    nonisolated static func dumpsys(closed: Bool) -> String {
        let inner = closed ? "OFF" : "ON"
        let cover = closed ? "ON" : "OFF"
        return """
          DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4600000000000000001", 1768 x 2208, modeId 3, renderFrameRate 60.000004, defaultModeId 1, supportedModes [{id=1, width=1768, height=2208, fps=120.00001, alternativeRefreshRates=[48.000004, 60.000004, 96.00001], supportedHdrTypes=[2, 3, 4]}, {id=2, width=1768, height=2208, fps=96.00001, alternativeRefreshRates=[48.000004, 60.000004, 120.00001], supportedHdrTypes=[2, 3, 4]}, {id=3, width=1768, height=2208, fps=60.000004, alternativeRefreshRates=[48.000004, 96.00001, 120.00001], supportedHdrTypes=[2, 3, 4]}, {id=4, width=1768, height=2208, fps=48.000004, alternativeRefreshRates=[60.000004, 96.00001, 120.00001], supportedHdrTypes=[2, 3, 4]}], colorMode 0, supportedColorModes [0, 7, 9], hdrCapabilities HdrCapabilities{mSupportedHdrTypes=[2, 3, 4], mMaxLuminance=400.0, mMaxAverageLuminance=200.00024, mMinLuminance=5.0E-4}, allmSupported false, gameContentTypeSupported false, density 420, 377.371 x 376.397 dpi, appVsyncOff 0, presDeadline 17666666, touch INTERNAL, rotation 0, type INTERNAL, address {port=130, model=0x40446df8ca940a}, deviceProductInfo DeviceProductInfo{name=, manufacturerPnpId=QCM, productId=1, modelYear=null, manufactureDate=ManufactureDate{week=27, year=2006}, connectionToSinkType=0}, state \(inner), committedState \(inner), frameRateOverride , brightnessMinimum 0.0, brightnessMaximum 1.0, brightnessDefault 0.5019608, hdrSdrRatio NaN, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=53, center=Point(53, 53)}, RoundedCorner{position=TopRight, radius=53, center=Point(1715, 53)}, RoundedCorner{position=BottomRight, radius=53, center=Point(1715, 2155)}, RoundedCorner{position=BottomLeft, radius=53, center=Point(53, 2155)}]}, FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY, FLAG_ROTATES_WITH_CONTENT, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_OWN_CONTENT_ONLY, FLAG_TRUSTED, installOrientation 3, displayShape DisplayShape{ spec=-311912193 displayWidth=1768 displayHeight=2208 physicalPixelDisplaySizeRatio=1.0 rotation=0 offsetX=0 offsetY=0 scale=1.0}}
          DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4600000000000000002", 832 x 2268, modeId 7, renderFrameRate 60.000004, defaultModeId 5, supportedModes [{id=5, width=832, height=2268, fps=120.00001, alternativeRefreshRates=[48.000004, 60.000004, 96.00001], supportedHdrTypes=[2, 3, 4]}, {id=6, width=832, height=2268, fps=96.00001, alternativeRefreshRates=[48.000004, 60.000004, 120.00001], supportedHdrTypes=[2, 3, 4]}, {id=7, width=832, height=2268, fps=60.000004, alternativeRefreshRates=[48.000004, 96.00001, 120.00001], supportedHdrTypes=[2, 3, 4]}, {id=8, width=832, height=2268, fps=48.000004, alternativeRefreshRates=[60.000004, 96.00001, 120.00001], supportedHdrTypes=[2, 3, 4]}], colorMode 0, supportedColorModes [0, 7, 9], hdrCapabilities HdrCapabilities{mSupportedHdrTypes=[2, 3, 4], mMaxLuminance=450.0, mMaxAverageLuminance=225.00024, mMinLuminance=5.0E-4}, allmSupported false, gameContentTypeSupported false, density 420, 391.348 x 389.237 dpi, appVsyncOff 0, presDeadline 17666666, cutout DisplayCutout{insets=Rect(0, 81 - 0, 0) waterfall=Insets{left=0, top=0, right=0, bottom=0} boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(385, 0 - 447, 81), Rect(0, 0 - 0, 0), Rect(0, 0 - 0, 0)]} cutoutPathParserInfo={CutoutPathParserInfo{displayWidth=832 displayHeight=2268 physicalDisplayWidth=832 physicalDisplayHeight=2268 density={2.625} cutoutSpec={M 0,0 H -11.80952380952381 V 30.85714285714286 H 11.80952380952381 V 0 H 0 Z @dp} rotation={0} scale={1.0} physicalPixelDisplaySizeRatio={1.0}}}}, touch INTERNAL, rotation 0, type INTERNAL, address {port=131, model=0x40446df8ca940a}, deviceProductInfo DeviceProductInfo{name=, manufacturerPnpId=QCM, productId=1, modelYear=null, manufactureDate=ManufactureDate{week=27, year=2006}, connectionToSinkType=0}, state \(cover), committedState \(cover), frameRateOverride , brightnessMinimum 0.0, brightnessMaximum 1.0, brightnessDefault 0.5019608, hdrSdrRatio NaN, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=53, center=Point(53, 53)}, RoundedCorner{position=TopRight, radius=53, center=Point(779, 53)}, RoundedCorner{position=BottomRight, radius=53, center=Point(779, 2215)}, RoundedCorner{position=BottomLeft, radius=53, center=Point(53, 2215)}]}, FLAG_ROTATES_WITH_CONTENT, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_PRESENTATION, FLAG_OWN_CONTENT_ONLY, FLAG_TRUSTED, FLAG_EXTRA_BUILT_IN_DISPLAY, installOrientation 0, displayShape DisplayShape{ spec=-311912193 displayWidth=832 displayHeight=2268 physicalPixelDisplaySizeRatio=1.0 rotation=0 offsetX=0 offsetY=0 scale=1.0}}
          Display 0:
            mPrimaryDisplayDevice=Built-in Screen
          Display 1:
            mPrimaryDisplayDevice=Built-in Screen

        """
    }

    /// `AndroidDisplayGeometry.probeScript`, trimmed to two of display 0's viewport lines; folded, `wm size` has an override.
    nonisolated static func geometry(closed: Bool) -> String {
        closed ? geometryClosed : geometryOpen
    }

    nonisolated static let geometryOpen = """
    Physical size: 1768x2208
    Physical density: 420
          Viewport INTERNAL: displayId=0, uniqueId=local:4600000000000000001, port=130, orientation=0, logicalFrame=[0, 0, 1768, 2208], physicalFrame=[0, 0, 1768, 2208], deviceSize=[1768, 2208], isActive=[1]
          Viewport INTERNAL: displayId=0, uniqueId=local:4600000000000000001, port=130, orientation=0, logicalFrame=[0, 0, 1768, 2208], physicalFrame=[0, 0, 1768, 2208], deviceSize=[1768, 2208], isActive=[1]

    """

    nonisolated static let geometryClosed = """
    Physical size: 832x2268
    Override size: 840x2289
    Physical density: 420
          Viewport INTERNAL: displayId=0, uniqueId=local:4600000000000000002, port=131, orientation=0, logicalFrame=[0, 0, 840, 2289], physicalFrame=[0, 0, 832, 2267], deviceSize=[832, 2268], isActive=[1]
          Viewport INTERNAL: displayId=0, uniqueId=local:4600000000000000002, port=131, orientation=0, logicalFrame=[0, 0, 840, 2289], physicalFrame=[0, 0, 832, 2267], deviceSize=[832, 2268], isActive=[1]

    """

    nonisolated static func status(closed: Bool) -> String {
        FoldableFixtures.status(printStates, state(closed: closed), dumpsys(closed: closed))
    }
}
