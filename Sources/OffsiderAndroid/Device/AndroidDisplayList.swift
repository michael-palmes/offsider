import Foundation
import OffsiderCore

/// The physical displays in `dumpsys display`, with roles, and the one under logical display 0.
struct AndroidDisplayList: Equatable, Sendable {
    struct Physical: Equatable, Sendable {
        /// Its platform id: the SurfaceFlinger id from `uniqueId="local:<id>"`, which `screencap -d` takes.
        var descriptor: DisplayDescriptor
        var uniqueId: String
        var external: Bool
        var on: Bool
    }

    var displays: [Physical]
    /// The `uniqueId` logical display 0 shows, which input, the tree and the default capture follow; One UI prints no id.
    var activeUniqueId: String?

    /// Plain `grep`, as in the geometry probe; the physical displays, logical display headers and their primary devices.
    static let command = "dumpsys display | grep -e 'DisplayDeviceInfo{' -e '^ *Display [0-9][0-9]*:' -e 'mPrimaryDisplayDevice='"

    var active: Physical? {
        displays.first { $0.uniqueId == activeUniqueId } ?? (displays.count == 1 ? displays.first : nil)
    }

    /// The only built-in panel that is on, which on a foldable is the active one unless both are lit.
    var soleLitPanel: Physical? {
        let lit = displays.filter { $0.on && !$0.external }
        return lit.count == 1 ? lit.first : nil
    }

    /// Built-in panels get `main`, or `cover` and `inner` by area; an external display is `external`; virtual ones are skipped.
    static func parse(dumpsys output: String) -> AndroidDisplayList {
        var found: [Physical] = []
        var activeUniqueId: String?
        var inLogicalDisplayZero = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DisplayDeviceInfo{"), let display = physical(in: line) {
                found.append(display)
            } else if line.hasPrefix("Display "), line.hasSuffix(":") {
                inLogicalDisplayZero = line == "Display 0:"
            } else if inLogicalDisplayZero, activeUniqueId == nil, line.hasPrefix("mPrimaryDisplayDevice="),
                      let open = line.lastIndex(of: "("), line.hasSuffix(")") {
                activeUniqueId = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            }
        }
        let builtIn = found.filter { !$0.external }
        let roles = DisplayDescriptor.assigningRoles(builtIn.map(\.descriptor))
        var displays: [Physical] = []
        for (display, descriptor) in zip(builtIn, roles) {
            var assigned = display
            assigned.descriptor = descriptor
            displays.append(assigned)
        }
        displays += found.filter(\.external)
        return AndroidDisplayList(displays: displays, activeUniqueId: activeUniqueId)
    }

    /// `DisplayDeviceInfo{"Built-in Screen": uniqueId="local:46...", 1080 x 2424, ... density 420, ... type INTERNAL, ... state ON, ...}`.
    private static func physical(in line: String) -> Physical? {
        guard let nameStart = line.range(of: "{\""),
              let nameEnd = line.range(of: "\": uniqueId=\"", range: nameStart.upperBound..<line.endIndex),
              let idEnd = line[nameEnd.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        let name = String(line[nameStart.upperBound..<nameEnd.lowerBound])
        let uniqueId = String(line[nameEnd.upperBound..<idEnd])
        let fields = line[line.index(after: idEnd)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let size = fields.first(where: { $0.contains(" x ") }).flatMap(Self.size),
              let density = fields.first(where: { $0.hasPrefix("density ") }).flatMap({ Int($0.dropFirst("density ".count)) }), density > 0,
              let type = fields.first(where: { $0.hasPrefix("type ") }).map({ String($0.dropFirst("type ".count)) }),
              type == "INTERNAL" || type == "EXTERNAL",
              uniqueId.hasPrefix("local:") else {
            return nil
        }
        let state = fields.first { $0.hasPrefix("state ") }.map { String($0.dropFirst("state ".count)) }
        let install = fields.first { $0.hasPrefix("installOrientation ") }.flatMap { Int($0.dropFirst("installOrientation ".count)) } ?? 0
        let descriptor = DisplayDescriptor(
            role: type == "EXTERNAL" ? .external : .main,
            platformId: String(uniqueId.dropFirst("local:".count)),
            name: name,
            pixelWidth: size.0,
            pixelHeight: size.1,
            scale: Double(density) / 160,
            nativeOrientation: (install % 4) * 90
        )
        return Physical(descriptor: descriptor, uniqueId: uniqueId, external: type == "EXTERNAL", on: state != "OFF")
    }

    private static func size(_ field: String) -> (Int, Int)? {
        let parts = field.components(separatedBy: " x ")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
