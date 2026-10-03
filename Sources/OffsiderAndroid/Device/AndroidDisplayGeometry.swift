import Foundation
import OffsiderCore

/// The guest display: natural panel size, logical size and rotation now, and density.
struct AndroidDisplayGeometry: Equatable, Sendable {
    let naturalWidth: Int
    let naturalHeight: Int
    let logicalWidth: Int
    let logicalHeight: Int
    /// `Surface.ROTATION_*`, 0 to 3, from the input viewport.
    let rotation: Int
    let densityDpi: Int
    /// Set when `wm size` reports an override, so the logical frame no longer maps one to one onto the panel.
    let hasSizeOverride: Bool

    var scale: Double { Double(densityDpi) / 160 }

    /// A large inner panel, such as a foldable's, is landscape at rotation 0.
    var naturalIsLandscape: Bool { naturalWidth > naturalHeight }

    /// The device's orientation, named as on iOS for the same physical turn.
    var deviceOrientation: DeviceOrientation {
        DeviceOrientation(androidRotation: rotation, naturalIsLandscape: naturalIsLandscape) ?? .portrait
    }

    var orientation: OrientationCoordinateMath.Orientation { deviceOrientation.coordinateOrientation }

    /// The same display after the guest turned to `rotation`; the logical size swaps when the turn is a quarter.
    func rotated(to rotation: Int) -> AndroidDisplayGeometry {
        guard (0...3).contains(rotation), rotation != self.rotation else { return self }
        let swaps = rotation % 2 != self.rotation % 2
        return AndroidDisplayGeometry(
            naturalWidth: naturalWidth,
            naturalHeight: naturalHeight,
            logicalWidth: swaps ? logicalHeight : logicalWidth,
            logicalHeight: swaps ? logicalWidth : logicalHeight,
            rotation: rotation,
            densityDpi: densityDpi,
            hasSizeOverride: hasSizeOverride
        )
    }

    /// Plain `grep`, not `-m1`: an early exit breaks dumpsys's pipe, which can hold the shell until dumpsys times out.
    static let probeScript = "wm size; wm density; dumpsys input | grep 'Viewport INTERNAL: displayId=0'"

    struct Unparseable: Error, Equatable {
        let firstLine: String
    }

    static func parse(_ output: String) throws -> AndroidDisplayGeometry {
        var natural: (Int, Int)?
        var override = false
        var physicalDensity: Int?
        var overrideDensity: Int?
        var viewport: (rotation: Int, width: Int, height: Int)?

        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("Physical size:") {
                natural = size(after: "Physical size:", in: line)
            } else if line.hasPrefix("Override size:") {
                override = size(after: "Override size:", in: line) != nil
            } else if line.hasPrefix("Physical density:") {
                physicalDensity = Int(line.dropFirst("Physical density:".count).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("Override density:") {
                overrideDensity = Int(line.dropFirst("Override density:".count).trimmingCharacters(in: .whitespaces))
            } else if line.contains("Viewport INTERNAL"), viewport == nil {
                viewport = parseViewport(line)
            }
        }

        guard let natural, let density = overrideDensity ?? physicalDensity, density > 0, let viewport else {
            let first = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
            throw Unparseable(firstLine: first)
        }
        return AndroidDisplayGeometry(
            naturalWidth: natural.0,
            naturalHeight: natural.1,
            logicalWidth: viewport.width,
            logicalHeight: viewport.height,
            rotation: viewport.rotation,
            densityDpi: density,
            hasSizeOverride: override
        )
    }

    /// The `uniqueId=local:<id>` of display 0's viewport, the physical display it shows now.
    static func viewportUniqueId(in output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("Viewport INTERNAL") }),
              let range = line.range(of: "uniqueId=") else {
            return nil
        }
        let value = line[range.upperBound...].prefix { $0 != "," && !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    private static func size(after prefix: String, in line: String) -> (Int, Int)? {
        let parts = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// `orientation=1, logicalFrame=[0, 0, 2424, 1080]`, with or without spaces after the commas.
    private static func parseViewport(_ line: String) -> (rotation: Int, width: Int, height: Int)? {
        guard let orientationRange = line.range(of: "orientation="),
              let rotation = line[orientationRange.upperBound...].first?.wholeNumberValue, (0...3).contains(rotation),
              let frameRange = line.range(of: "logicalFrame=["),
              let close = line[frameRange.upperBound...].firstIndex(of: "]") else {
            return nil
        }
        let numbers = line[frameRange.upperBound..<close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4 else { return nil }
        let width = numbers[2] - numbers[0]
        let height = numbers[3] - numbers[1]
        guard width > 0, height > 0 else { return nil }
        return (rotation, width, height)
    }
}

extension AndroidDisplayGeometry {
    /// From the helper's display; nil when it had no rotation (its fallback read), so the shell probe runs instead.
    init?(display: HelperDisplay) {
        guard let rotation = display.rotation, (0...3).contains(rotation), display.densityDpi > 0,
              display.logicalWidthPx > 0, display.logicalHeightPx > 0 else {
            return nil
        }
        let quarter = rotation % 2 == 1
        let unrotatedWidth = quarter ? display.logicalHeightPx : display.logicalWidthPx
        let unrotatedHeight = quarter ? display.logicalWidthPx : display.logicalHeightPx
        let naturalWidth = display.physicalWidthPx ?? unrotatedWidth
        let naturalHeight = display.physicalHeightPx ?? unrotatedHeight
        self.init(
            naturalWidth: naturalWidth,
            naturalHeight: naturalHeight,
            logicalWidth: display.logicalWidthPx,
            logicalHeight: display.logicalHeightPx,
            rotation: rotation,
            densityDpi: display.densityDpi,
            hasSizeOverride: unrotatedWidth != naturalWidth || unrotatedHeight != naturalHeight
        )
    }
}
