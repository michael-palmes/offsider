import Foundation

/// What `displays` and `posture` print.
public enum DisplayReport {
    public static func table(_ list: DisplayList, platform: DevicePlatform) -> String {
        let unit = platform == .android ? "dp" : "pt"
        let header = ["ID", "PLATFORM ID", "SIZE", "SCALE", "ROTATION", "ACTIVE"]
        let rows = list.displays.map { display in
            [
                display.descriptor.role.rawValue,
                display.descriptor.platformId,
                "\(number(display.pointWidth))x\(number(display.pointHeight)) \(unit)",
                OrderedJSON.formatNumber(display.descriptor.scale),
                display.rotationDegrees.map(String.init) ?? "-",
                display.active ? "yes" : "no",
            ]
        }
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        let lines = all.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return (lines + ["Posture: \(list.posture?.rawValue ?? "not foldable")"]).joined(separator: "\n")
    }

    public static func json(_ list: DisplayList) -> String {
        OrderedJSON.object([
            ("displays", .array(list.displays.map { display in
                .object([
                    ("id", .string(display.descriptor.role.rawValue)),
                    ("platformId", .string(display.descriptor.platformId)),
                    ("name", .string(display.descriptor.name)),
                    ("width", .number(display.pointWidth)),
                    ("height", .number(display.pointHeight)),
                    ("scale", .number(display.descriptor.scale)),
                    ("rotation", .optional(display.rotationDegrees, OrderedJSON.integer)),
                    ("active", .bool(display.active)),
                ])
            })),
            ("posture", .optional(list.posture?.rawValue, OrderedJSON.string)),
        ]).rendered(compact: true)
    }

    /// `Posture: open (inner, 669 x 951 pt)`.
    public static func postureLine(_ posture: Posture, screen: UIScreenInfo?, platform: DevicePlatform) -> String {
        var text = "Posture: \(posture.rawValue)"
        if let screen {
            let unit = platform == .android ? "dp" : "pt"
            text += " (\(screen.resolvedDisplay(on: platform).id), \(number(screen.width)) x \(number(screen.height)) \(unit))"
        }
        return text
    }

    public static func postureJSON(_ posture: Posture, previous: Posture?, screen: UIScreenInfo?, platform: DevicePlatform) -> String {
        OrderedJSON.object([
            ("posture", .string(posture.rawValue)),
            ("previous", .optional(previous?.rawValue, OrderedJSON.string)),
            ("display", .optional(screen?.resolvedDisplay(on: platform).id, OrderedJSON.string)),
            ("screen", .optional(screen) { .object([("width", .number($0.width)), ("height", .number($0.height))]) }),
        ]).rendered(compact: true)
    }

    public static func notFoldable(device: String) -> String {
        "\(device) is not a foldable device; it has one display."
    }

    /// For `describe-ui --display` naming a display that is not showing anything.
    public static func inactiveDisplay(_ requested: DisplayInfo, posture: Posture?, platform: DevicePlatform, device: String) -> String {
        let role = requested.descriptor.role.rawValue
        let state = "describe-ui reads the active display only, and \(role) is not active (posture \(posture?.rawValue ?? "unknown"))."
        let verb = requested.descriptor.role == .cover ? "Fold" : "Unfold"
        switch platform {
        case .ios:
            return "\(state) \(verb) the simulator in Device Hub, then retry."
        case .android:
            let target = requested.descriptor.role == .cover ? "closed" : "open"
            return "\(state) \(verb) the emulator with `offsider posture \(target) --device \(device)`, then retry."
        }
    }

    private static func number(_ value: Double) -> String {
        OrderedJSON.formatNumber((value * 100).rounded() / 100)
    }
}
