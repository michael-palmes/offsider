import Foundation

public enum Appearance: String, CaseIterable, Sendable {
    case light
    case dark
}

/// What the device reports: light or dark, or an Android night mode such as `auto` or `custom` that follows a schedule.
public enum AppearanceReading: Equatable, Sendable {
    case fixed(Appearance)
    case scheduled(String)

    public var appearance: Appearance? {
        guard case .fixed(let appearance) = self else { return nil }
        return appearance
    }

    public var name: String {
        switch self {
        case .fixed(let appearance): return appearance.rawValue
        case .scheduled(let mode): return mode
        }
    }
}

/// Dynamic Type sizes on iOS; on Android, a font scale for each.
public enum ContentSizeCategory: String, CaseIterable, Sendable {
    case extraSmall = "extra-small"
    case small
    case medium
    case large
    case extraLarge = "extra-large"
    case extraExtraLarge = "extra-extra-large"
    case extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium"
    case accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"

    /// The simulator's content size index, 1 (extra-small) to 12.
    public var iosIndex: Int {
        Self.allCases.firstIndex(of: self)! + 1
    }

    public init?(iosIndex: Int) {
        guard (1...Self.allCases.count).contains(iosIndex) else { return nil }
        self = Self.allCases[iosIndex - 1]
    }

    /// `large` is Android's default 1.0; the steps follow Android's own 0.85, 1.15, 1.3, 1.5, 1.8 and 2.0 where they exist.
    public var androidFontScale: Double {
        switch self {
        case .extraSmall: return 0.8
        case .small: return 0.85
        case .medium: return 0.9
        case .large: return 1.0
        case .extraLarge: return 1.15
        case .extraExtraLarge: return 1.3
        case .extraExtraExtraLarge: return 1.5
        case .accessibilityMedium: return 1.65
        case .accessibilityLarge: return 1.8
        case .accessibilityExtraLarge: return 2.0
        case .accessibilityExtraExtraLarge: return 2.2
        case .accessibilityExtraExtraExtraLarge: return 2.4
        }
    }

    public static func nearest(androidFontScale scale: Double) -> ContentSizeCategory {
        allCases.min { abs($0.androidFontScale - scale) < abs($1.androidFontScale - scale) }!
    }

    /// `reset` means `large`, the platform default.
    public static func parse(_ text: String) throws -> ContentSizeCategory {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "reset" { return .large }
        guard let category = ContentSizeCategory(rawValue: trimmed) else {
            let names = (allCases.map(\.rawValue) + ["reset"]).joined(separator: ", ")
            throw DeviceSettingsError("Unknown size '\(text)'. Use one of: \(names).")
        }
        return category
    }
}

public struct ContentSizeReading: Equatable, Sendable {
    public let category: ContentSizeCategory
    /// Android only: the exact `font_scale`, which may sit between two categories.
    public let fontScale: Double?

    public init(category: ContentSizeCategory, fontScale: Double?) {
        self.category = category
        self.fontScale = fontScale
    }
}

/// Named after UIKit's interface orientation, as the frontmost app reports it.
public enum DeviceOrientation: String, CaseIterable, Sendable {
    case portrait
    case landscapeLeft = "landscape-left"
    case landscapeRight = "landscape-right"
    case portraitUpsideDown = "portrait-upside-down"

    /// The one table between public names, coordinate math, the idb orientation event and Android's `user_rotation`.
    /// Measured on iOS 27: idb event 3 turns the app to landscape-right, which SimulatorKit reports as `uiOrientation` 4.
    struct Mapping {
        let orientation: DeviceOrientation
        let coordinate: OrientationCoordinateMath.Orientation
        let iosEvent: Int32
        let androidRotation: Int
    }

    static let table: [Mapping] = [
        Mapping(orientation: .portrait, coordinate: .portrait, iosEvent: 1, androidRotation: 0),
        Mapping(orientation: .landscapeLeft, coordinate: .landscape, iosEvent: 4, androidRotation: 3),
        Mapping(orientation: .landscapeRight, coordinate: .landscapeFlipped, iosEvent: 3, androidRotation: 1),
        Mapping(orientation: .portraitUpsideDown, coordinate: .portraitUpsideDown, iosEvent: 2, androidRotation: 2),
    ]

    private var mapping: Mapping { Self.table.first { $0.orientation == self }! }

    public var coordinateOrientation: OrientationCoordinateMath.Orientation { mapping.coordinate }

    /// `FBSimulatorHIDDeviceOrientation`'s raw value, which follows `UIDeviceOrientation`.
    public var iosEventValue: Int32 { mapping.iosEvent }

    /// `Surface.ROTATION_*` for `settings put system user_rotation`.
    public var androidRotation: Int { mapping.androidRotation }

    public init(coordinateOrientation: OrientationCoordinateMath.Orientation) {
        self = Self.table.first { $0.coordinate == coordinateOrientation }!.orientation
    }

    public init?(androidRotation: Int) {
        guard let row = Self.table.first(where: { $0.androidRotation == androidRotation }) else { return nil }
        self = row.orientation
    }

    public var isLandscape: Bool { coordinateOrientation.isLandscape }
}

extension OrientationCoordinateMath.Orientation {
    /// Counterclockwise quarter turns that make a portrait-native framebuffer image match the logical screen.
    public var uprightQuarterTurnsCounterclockwise: Int {
        switch self {
        case .portrait: return 0
        case .landscapeFlipped: return 1
        case .portraitUpsideDown: return 2
        case .landscape: return 3
        }
    }
}

public struct DeviceSettingsError: Error, CustomStringConvertible, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Optional capability: system appearance and text size.
@MainActor
public protocol DeviceSettingsControlling: DeviceBackend {
    func appearance(on id: DeviceID) async throws -> AppearanceReading
    func setAppearance(_ appearance: Appearance, on id: DeviceID) async throws
    func contentSize(on id: DeviceID) async throws -> ContentSizeReading
    func setContentSize(_ category: ContentSizeCategory, on id: DeviceID) async throws
}

/// Optional capability: the shake gesture.
@MainActor
public protocol DeviceShaking: DeviceBackend {
    func shake(_ id: DeviceID) async throws
}

/// Optional capability: reading and turning the interface orientation.
@MainActor
public protocol OrientationControlling: DeviceBackend {
    /// Nil when the device cannot report it.
    func orientation(of id: DeviceID) async throws -> DeviceOrientation?
    /// Dispatch only; poll `orientation(of:)` to see it take effect.
    func requestOrientation(_ orientation: DeviceOrientation, on id: DeviceID) async throws
}

public enum OrientationWait {
    public enum Outcome: Equatable, Sendable {
        case reached
        case timedOut(last: DeviceOrientation?)
    }

    /// Reads at least once; sends `request` again once, halfway to the deadline, in case the first was dropped.
    @MainActor
    public static func run(
        target: DeviceOrientation,
        timeout: TimeInterval,
        interval: Duration = .milliseconds(100),
        read: @MainActor () async throws -> DeviceOrientation?,
        request: @MainActor () async throws -> Void,
        sleep: @MainActor (Duration) async throws -> Void,
        now: @MainActor () -> TimeInterval
    ) async throws -> Outcome {
        let start = now()
        var resent = false
        while true {
            let current = try await read()
            if current == target { return .reached }
            let elapsed = now() - start
            if elapsed >= timeout { return .timedOut(last: current) }
            if !resent, elapsed >= timeout / 2 {
                resent = true
                try await request()
            }
            try await sleep(interval)
        }
    }
}

/// The JSON lines `appearance`, `content-size` and `orientation` print with `--json`.
public enum DeviceSettingsReport {
    /// Whole numbers without a decimal point, as the JSON prints them.
    public static func number(_ value: Double) -> String {
        OrderedJSON.formatNumber(value)
    }

    public static func appearance(_ current: Appearance, previous: Appearance?) -> String {
        appearance(.fixed(current), previous: previous)
    }

    public static func appearance(_ current: AppearanceReading, previous: Appearance?) -> String {
        OrderedJSON.object([
            ("appearance", .string(current.name)),
            ("previous", .optional(previous) { .string($0.rawValue) }),
        ]).rendered(compact: true)
    }

    public static func contentSize(_ current: ContentSizeReading, previous: ContentSizeReading?) -> String {
        OrderedJSON.object([
            ("contentSize", .string(current.category.rawValue)),
            ("previous", .optional(previous) { .string($0.category.rawValue) }),
            ("fontScale", .optional(current.fontScale) { .number($0) }),
        ]).rendered(compact: true)
    }

    public static func orientation(_ current: DeviceOrientation, previous: DeviceOrientation?, screen: UIScreenInfo?) -> String {
        OrderedJSON.object([
            ("orientation", .string(current.rawValue)),
            ("previous", .optional(previous) { .string($0.rawValue) }),
            ("screen", .optional(screen) { .object([("width", .number($0.width)), ("height", .number($0.height))]) }),
        ]).rendered(compact: true)
    }
}
