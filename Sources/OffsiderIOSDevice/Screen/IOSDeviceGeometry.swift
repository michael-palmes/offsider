import Foundation
import OffsiderCore

/// The main display from `devicectl device info displays`: the portrait panel in pixels, its point scale and the UI's turn.
public struct IOSDeviceGeometry: Codable, Equatable, Sendable {
    public var pixelWidth: Double
    public var pixelHeight: Double
    public var pointScale: Double
    /// Anticlockwise from portrait; the motion `orientation` block is ignored because it follows the hardware, not the UI.
    public var rotationDegrees: Int?

    public init(pixelWidth: Double, pixelHeight: Double, pointScale: Double, rotationDegrees: Int?) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointScale = pointScale
        self.rotationDegrees = rotationDegrees
    }

    public struct ParseError: Error, Equatable, Sendable {
        public let detail: String
    }

    static let fileName = "geometry.json"
    static let infoArguments = ["device", "info", "displays", "--timeout", "20", "--json-output", "-", "-q"]

    public static func parse(_ data: Data) throws -> IOSDeviceGeometry {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]], !displays.isEmpty else {
            throw ParseError(detail: "no displays in the reply")
        }
        let display = displays.first { $0["primary"] as? Bool == true } ?? displays[0]
        let size = pair(display["nativeSize"]) ?? (display["bounds"] as? [Any]).flatMap { $0.count == 2 ? pair($0[1]) : nil }
        guard let size, size.0 > 0, size.1 > 0,
              let scale = (display["pointScale"] as? NSNumber)?.doubleValue, scale > 0 else {
            throw ParseError(detail: "the main display has no size or point scale")
        }
        let clockwise = DevicectlDisplays.degrees(display["currentOrientation"] as? String)
        return IOSDeviceGeometry(
            pixelWidth: min(size.0, size.1),
            pixelHeight: max(size.0, size.1),
            pointScale: scale,
            rotationDegrees: clockwise.map(DevicectlDisplays.anticlockwise)
        )
    }

    public var orientation: OrientationCoordinateMath.Orientation? {
        rotationDegrees.flatMap(DeviceOrientation.init(rotationDegrees:))?.coordinateOrientation
    }

    /// Points in the current orientation.
    public var screenInfo: UIScreenInfo {
        let width = pixelWidth / pointScale
        let height = pixelHeight / pointScale
        let landscape = orientation?.isLandscape == true
        return UIScreenInfo(
            width: landscape ? height : width,
            height: landscape ? width : height,
            scale: pointScale,
            rotation: orientation,
            rotationDegrees: rotationDegrees
        )
    }

    private static func pair(_ value: Any?) -> (Double, Double)? {
        guard let array = value as? [Any], array.count == 2,
              let first = (array[0] as? NSNumber)?.doubleValue, let second = (array[1] as? NSNumber)?.doubleValue else {
            return nil
        }
        return (first, second)
    }
}

extension [String] {
    /// devicectl's `--device <udid>` after the subcommand words.
    func inserting(device udid: String) -> [String] {
        let words = prefix { !$0.hasPrefix("-") }
        return Array(words) + ["--device", udid] + dropFirst(words.count)
    }
}
