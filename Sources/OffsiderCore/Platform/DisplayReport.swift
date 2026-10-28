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

    /// A person sees the posture, then a row per display with the active one lit; an agent reads `table` as it is.
    public static func page(_ list: DisplayList, platform: DevicePlatform) -> Page {
        let unit = platform == .android ? "dp" : "pt"
        let columns = [
            Table.Column(agent: nil, person: 0, tone: .bold),
            Table.Column(agent: nil, person: 1),
            Table.Column(agent: nil, person: 2, fit: .optional(priority: 2), tone: .dim),
            Table.Column(agent: nil, person: 3, fit: .optional(priority: 1), tone: .dim),
            Table.Column(agent: nil, person: 4, fit: .optional(priority: 0), tone: .dim),
        ]
        let rows = list.displays.map { display in
            Table.Row([
                Table.Cell(display.descriptor.role.rawValue, tag: display.active ? "active" : nil),
                Table.Cell("\(number(display.pointWidth)) x \(number(display.pointHeight)) \(unit)"),
                Table.Cell(OrderedJSON.formatNumber(display.descriptor.scale) + "x"),
                display.rotationDegrees.map { Table.Cell("\($0)°") },
                Table.Cell("id " + display.descriptor.platformId, untrusted: true),
            ], status: display.active ? .on : .off)
        }
        let header = Header(platform == .android ? .android : .iPhone, "Displays", [list.posture.map { "posture \($0.rawValue)" } ?? "not foldable"])
        return Page([.person([.header(header), .table(Table(columns: columns, rows: rows))]), .agent(table(list, platform: platform) + "\n")])
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

    /// `Posture: open (inner, 669 x 951 pt)`, with a `state` that is not the posture's own name after it: `open (One UI DUAL)`.
    public static func postureLine(_ posture: Posture, screen: UIScreenInfo?, platform: DevicePlatform, state: String? = nil) -> String {
        var text = "Posture: \(posture.rawValue)\(stateNote(state))"
        if let screen {
            let unit = platform == .android ? "dp" : "pt"
            text += " (\(screen.resolvedDisplay(on: platform).id), \(number(screen.width)) x \(number(screen.height)) \(unit))"
        }
        return text
    }

    /// `posture reset --json`: whether an override was dropped, and the posture the hinge then gives.
    public static func postureResetJSON(reset: Bool, current: Posture, state: String?) -> String {
        OrderedJSON.object([
            ("version", .integer(1)), ("action", .string("reset")), ("reset", .bool(reset)),
            ("posture", .string(current.rawValue)), ("state", .optional(state) { .string($0) }),
        ]).rendered(compact: true)
    }

    public static func postureJSON(_ posture: Posture, previous: Posture?, screen: UIScreenInfo?, platform: DevicePlatform, state: String? = nil) -> String {
        OrderedJSON.object([
            ("posture", .string(posture.rawValue)),
            ("state", .optional(state, OrderedJSON.string)),
            ("previous", .optional(previous?.rawValue, OrderedJSON.string)),
            ("display", .optional(screen?.resolvedDisplay(on: platform).id, OrderedJSON.string)),
            ("screen", .optional(screen) { .object([("width", .number($0.width)), ("height", .number($0.height))]) }),
        ]).rendered(compact: true)
    }

    /// Names that are a posture's own, AOSP's and One UI's, which need no note.
    static let plainStateNames: Set<String> = ["CLOSED", "CLOSE", "HALF_OPENED", "HALF_FOLDED", "OPENED", "OPEN"]
    static let oneUIStateNames: Set<String> = ["TENT", "DUAL", "REAR_DUAL"]

    static func stateNote(_ state: String?) -> String {
        guard let state, !state.isEmpty, !plainStateNames.contains(state.uppercased()) else { return "" }
        return oneUIStateNames.contains(state.uppercased()) ? " (One UI \(state))" : " (state \(state))"
    }

    public static func notFoldable(device: String) -> String {
        "\(device) is not a foldable device; it has one display."
    }

    /// For `describe-ui --display` naming a display that is not showing anything.
    public static func inactiveDisplay(_ requested: DisplayInfo, posture: Posture?, platform: DevicePlatform, physical: Bool = false, device: String) -> String {
        let role = requested.descriptor.role.rawValue
        let state = "describe-ui reads the active display only, and \(role) is not active (posture \(posture?.rawValue ?? "unknown"))."
        let verb = requested.descriptor.role == .cover ? "Fold" : "Unfold"
        guard !physical else { return "\(state) \(verb) the phone, then retry." }
        let target = requested.descriptor.role == .cover ? "closed" : "open"
        let noun = platform == .ios ? "simulator" : "emulator"
        return "\(state) \(verb) the \(noun) with `offsider posture \(target) --device \(device)`, then retry."
    }

    private static func number(_ value: Double) -> String {
        OrderedJSON.formatNumber((value * 100).rounded() / 100)
    }
}
