import Foundation

/// What `xcrun devicectl device info displays --json-output` reports for a simulator.
public struct DevicectlDisplays: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var displayId: Int
        public var name: String
        public var active: Bool
        public var primary: Bool
        /// Degrees from `currentOrientation` (`rot90` is 90); nil when missing or unrecognised.
        public var currentRotation: Int?
        public var integrated: Bool

        public init(displayId: Int, name: String, active: Bool, primary: Bool, currentRotation: Int?, integrated: Bool) {
            self.displayId = displayId
            self.name = name
            self.active = active
            self.primary = primary
            self.currentRotation = currentRotation
            self.integrated = integrated
        }
    }

    public var displays: [Entry]

    public init(displays: [Entry]) {
        self.displays = displays
    }

    public static func parse(json data: Data) throws -> DevicectlDisplays {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["displays"] as? [[String: Any]] else {
            throw DeviceSettingsError("devicectl did not report any displays.")
        }
        return DevicectlDisplays(displays: entries.compactMap { entry in
            guard let id = (entry["displayId"] as? NSNumber)?.intValue else { return nil }
            return Entry(
                displayId: id,
                name: entry["name"] as? String ?? "",
                active: entry["active"] as? Bool ?? false,
                primary: entry["primary"] as? Bool ?? false,
                currentRotation: degrees(entry["currentOrientation"] as? String),
                integrated: (entry["type"] as? [String: Any])?["integrated"] != nil
            )
        })
    }

    /// `rot0`, `rot90`, `rot180` or `rot270` as degrees.
    public static func degrees(_ text: String?) -> Int? {
        guard let text, text.hasPrefix("rot"), let value = Int(text.dropFirst(3)), [0, 90, 180, 270].contains(value) else {
            return nil
        }
        return value
    }

    /// The first `Angle:` reading in `devicectl device motion hinge-angle` output.
    public static func hingeAngle(in text: String) -> Double? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "Angle:") else { continue }
            let value = line[range.upperBound...].split(separator: " ", omittingEmptySubsequences: true).first
            if let value, let angle = Double(value) { return angle }
        }
        return nil
    }
}

/// Which built-in display is active, and the posture that follows from it.
public struct ActiveDisplay: Equatable, Sendable {
    public enum Source: String, Sendable {
        case single
        case devicectl
        case applicationFrame
        case fallback
    }

    public var descriptor: DisplayDescriptor
    /// From devicectl; nil when it did not say.
    public var rotationDegrees: Int?
    /// Nil on a device with one display.
    public var posture: Posture?
    public var source: Source
    /// devicectl's rotation for each display, by platform id.
    public var rotations: [String: Int]

    public init(descriptor: DisplayDescriptor, rotationDegrees: Int?, posture: Posture?, source: Source, rotations: [String: Int] = [:]) {
        self.descriptor = descriptor
        self.rotationDegrees = rotationDegrees
        self.posture = posture
        self.source = source
        self.rotations = rotations
    }

    /// devicectl first, then the application frame matched against each display's points, then screen 1 with an unknown posture.
    public static func resolve(
        profile: [DisplayDescriptor],
        devicectl: DevicectlDisplays?,
        applicationFrame: (width: Double, height: Double)?
    ) -> ActiveDisplay? {
        guard let first = profile.first else { return nil }
        guard profile.count > 1 else {
            return ActiveDisplay(descriptor: first, rotationDegrees: nil, posture: nil, source: .single)
        }
        var rotations: [String: Int] = [:]
        for entry in devicectl?.displays ?? [] {
            if let rotation = entry.currentRotation { rotations[String(entry.displayId)] = rotation }
        }
        if let entry = devicectl?.displays.first(where: \.active),
           let descriptor = profile.first(where: { $0.platformId == String(entry.displayId) }) {
            return ActiveDisplay(
                descriptor: descriptor, rotationDegrees: entry.currentRotation, posture: posture(for: descriptor.role),
                source: .devicectl, rotations: rotations
            )
        }
        if let frame = applicationFrame {
            let matches = profile.filter { matches(frame, $0) }
            if matches.count == 1 {
                return ActiveDisplay(descriptor: matches[0], rotationDegrees: nil, posture: posture(for: matches[0].role), source: .applicationFrame, rotations: rotations)
            }
        }
        let fallback = profile.first { $0.platformId == "1" } ?? first
        return ActiveDisplay(descriptor: fallback, rotationDegrees: nil, posture: .unknown, source: .fallback, rotations: rotations)
    }

    /// Closed on the cover, open on the inner display; a half-opened posture needs a hinge reading.
    public static func posture(for role: DisplayRole) -> Posture {
        switch role {
        case .cover: return .closed
        case .inner: return .open
        case .main, .external: return .unknown
        }
    }

    private static func matches(_ frame: (width: Double, height: Double), _ display: DisplayDescriptor) -> Bool {
        let close = { (a: Double, b: Double) in abs(a - b) <= 1 }
        return (close(frame.width, display.pointWidth) && close(frame.height, display.pointHeight))
            || (close(frame.width, display.pointHeight) && close(frame.height, display.pointWidth))
    }
}
