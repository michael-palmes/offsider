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

    /// Named so rotation 1 and 3 match `OrientationCoordinateMath` for the same physical turn on iOS.
    var orientation: OrientationCoordinateMath.Orientation {
        switch rotation {
        case 1: return .landscapeFlipped
        case 2: return .portraitUpsideDown
        case 3: return .landscape
        default: return .portrait
        }
    }

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
