import Foundation

/// What one dump reads; the defaults match `uiautomator dump --compressed` for the app and its keyboard.
struct HelperDumpOptions: Equatable, Sendable {
    /// "app": the active window and keyboard trees; "all": every window.
    var windows = "app"
    var notImportant = false
    var visibleOnly = true
    var testTags = true
    var idleQuietMs = 100
    var idleTimeoutMs = 500
}

/// One request; `fields` are the op's own keys beside `id` and `op`.
struct HelperRequest: Equatable, Sendable {
    let op: String
    let fields: [String: HelperValue]

    static func hello(token: String) -> HelperRequest {
        HelperRequest(op: "hello", fields: ["token": .string(token), "protocol": .int(HelperDex.protocolVersion)])
    }

    static let ping = HelperRequest(op: "ping", fields: [:])
    static let display = HelperRequest(op: "display", fields: [:])
    static let quit = HelperRequest(op: "quit", fields: [:])

    static func dump(_ options: HelperDumpOptions) -> HelperRequest {
        HelperRequest(op: "dump", fields: [
            "windows": .string(options.windows),
            "notImportant": .bool(options.notImportant),
            "visibleOnly": .bool(options.visibleOnly),
            "testTags": .bool(options.testTags),
            "idleQuietMs": .int(options.idleQuietMs),
            "idleTimeoutMs": .int(options.idleTimeoutMs),
        ])
    }

    /// `ACTION_SET_PROGRESS` in the node's own units; `expect` is the range as dumped, so a changed range is refused as stale.
    static func setProgress(_ node: HelperNodeRef, value: Double, expecting range: HelperRange) -> HelperRequest {
        var ref: [String: HelperValue] = ["generation": .int(node.generation), "index": .int(node.index)]
        ref["className"] = node.className.map(HelperValue.string)
        ref["resourceId"] = node.resourceId.map(HelperValue.string)
        return HelperRequest(op: "setProgress", fields: [
            "node": .object(ref),
            "value": .double(value),
            "expect": .object(["min": .double(range.min), "max": .double(range.max)]),
        ])
    }

    /// Relevant events after `since`, waiting up to `waitMs` for the first.
    static func events(since: Int64, waitMs: Int) -> HelperRequest {
        HelperRequest(op: "events", fields: ["since": .int(Int(since)), "waitMs": .int(waitMs)])
    }

    /// `ACTION_SET_TEXT` on the field with input focus.
    static func setText(_ text: String) -> HelperRequest {
        HelperRequest(op: "setText", fields: ["text": .string(text)])
    }

    /// The JSON payload with sorted keys, so the same request always encodes the same way.
    func payload(id: Int) throws -> Data {
        var object = fields
        object["id"] = .int(id)
        object["op"] = .string(op)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(object)
    }
}

/// The JSON values requests carry.
indirect enum HelperValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: HelperValue])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The fields every frame from the helper may carry: a reply's `id`, `ok` and `error`, or a `bye` event.
struct HelperEnvelope: Decodable, Equatable, Sendable {
    let id: Int?
    let ok: Bool?
    let event: String?
    let reason: String?
    let detail: String?
    let error: HelperErrorBody?
    let eventSeq: Int64?
}

struct HelperErrorBody: Decodable, Error, Equatable, Sendable {
    let code: String
    let message: String
    let detail: String?
    let className: String?
    let resourceId: String?
}

struct HelperHello: Decodable, Equatable, Sendable {
    let helper: String
    let `protocol`: Int
}

struct HelperRange: Codable, Equatable, Sendable {
    /// "int", "float", "percent" or "indeterminate".
    let type: String
    /// NaN when the helper sent null for a value Android reported as not a number.
    let min: Double
    let max: Double
    let current: Double

    init(type: String, min: Double, max: Double, current: Double) {
        self.type = type
        self.min = min
        self.max = max
        self.current = current
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "indeterminate"
        min = try container.decodeIfPresent(Double.self, forKey: .min) ?? .nan
        max = try container.decodeIfPresent(Double.self, forKey: .max) ?? .nan
        current = try container.decodeIfPresent(Double.self, forKey: .current) ?? .nan
    }

    static func == (lhs: HelperRange, rhs: HelperRange) -> Bool {
        func same(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }
        return lhs.type == rhs.type && same(lhs.min, rhs.min) && same(lhs.max, rhs.max) && same(lhs.current, rhs.current)
    }
}

struct HelperDisplay: Decodable, Equatable, Sendable {
    let source: String
    let logicalWidthPx: Int
    let logicalHeightPx: Int
    /// nil when the hidden display API was unavailable and the helper fell back to the system resources.
    let rotation: Int?
    /// The display mode's size, which ignores a `wm size` override; in the panel's natural orientation.
    let physicalWidthPx: Int?
    let physicalHeightPx: Int?
    let densityDpi: Int

    init(source: String, logicalWidthPx: Int, logicalHeightPx: Int, rotation: Int?, physicalWidthPx: Int?, physicalHeightPx: Int?, densityDpi: Int) {
        self.source = source
        self.logicalWidthPx = logicalWidthPx
        self.logicalHeightPx = logicalHeightPx
        self.rotation = rotation
        self.physicalWidthPx = physicalWidthPx
        self.physicalHeightPx = physicalHeightPx
        self.densityDpi = densityDpi
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        logicalWidthPx = try container.decode(Int.self, forKey: .logicalWidthPx)
        logicalHeightPx = try container.decode(Int.self, forKey: .logicalHeightPx)
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation)
        physicalWidthPx = try container.decodeIfPresent(Int.self, forKey: .physicalWidthPx)
        physicalHeightPx = try container.decodeIfPresent(Int.self, forKey: .physicalHeightPx)
        densityDpi = try container.decode(Int.self, forKey: .densityDpi)
    }

    private enum CodingKeys: String, CodingKey {
        case source, logicalWidthPx, logicalHeightPx, rotation, physicalWidthPx, physicalHeightPx, densityDpi
    }
}

/// One node; booleans arrive only when they differ from the default (false, or true for `enabled` and `visibleToUser`).
struct HelperNode: Decodable, Equatable, Sendable {
    /// Pre-order index across the whole dump generation.
    let i: Int
    let `class`: String?
    let package: String?
    let resourceId: String?
    let text: String?
    let contentDescription: String?
    let hint: String?
    let stateDescription: String?
    let roleDescription: String?
    let testTag: String?
    /// `[left, top, right, bottom]` in pixels in the current rotation.
    let bounds: [Int]
    let checkable: Bool
    let checked: Bool
    /// "checked", "unchecked" or "partial" (API 36 and later).
    let checkedState: String?
    let clickable: Bool
    let longClickable: Bool
    let enabled: Bool
    let focusable: Bool
    let focused: Bool
    let scrollable: Bool
    let selected: Bool
    let editable: Bool
    let password: Bool
    let visibleToUser: Bool
    let rangeInfo: HelperRange?
    let children: [HelperNode]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys, _ fallback: Bool = false) throws -> Bool {
            try c.decodeIfPresent(Bool.self, forKey: key) ?? fallback
        }
        i = try c.decode(Int.self, forKey: .i)
        `class` = try c.decodeIfPresent(String.self, forKey: .class)
        package = try c.decodeIfPresent(String.self, forKey: .package)
        resourceId = try c.decodeIfPresent(String.self, forKey: .resourceId)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        contentDescription = try c.decodeIfPresent(String.self, forKey: .contentDescription)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        stateDescription = try c.decodeIfPresent(String.self, forKey: .stateDescription)
        roleDescription = try c.decodeIfPresent(String.self, forKey: .roleDescription)
        testTag = try c.decodeIfPresent(String.self, forKey: .testTag)
        bounds = try c.decodeIfPresent([Int].self, forKey: .bounds) ?? []
        checkable = try flag(.checkable)
        checked = try flag(.checked)
        checkedState = try c.decodeIfPresent(String.self, forKey: .checkedState)
        clickable = try flag(.clickable)
        longClickable = try flag(.longClickable)
        enabled = try flag(.enabled, true)
        focusable = try flag(.focusable)
        focused = try flag(.focused)
        scrollable = try flag(.scrollable)
        selected = try flag(.selected)
        editable = try flag(.editable)
        password = try flag(.password)
        visibleToUser = try flag(.visibleToUser, true)
        rangeInfo = try c.decodeIfPresent(HelperRange.self, forKey: .rangeInfo)
        children = try c.decodeIfPresent([HelperNode].self, forKey: .children) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case i, `class`, package, resourceId, text, contentDescription, hint, stateDescription, roleDescription, testTag
        case bounds, checkable, checked, checkedState, clickable, longClickable, enabled, focusable, focused, scrollable
        case selected, editable, password, visibleToUser, rangeInfo, children
    }
}

/// Windows arrive in z-order; `root` is absent for windows the dump did not walk and null when it found none.
struct HelperWindow: Decodable, Equatable, Sendable {
    let id: Int
    /// "application", "inputMethod", "system", "accessibilityOverlay" and so on.
    let type: String
    let layer: Int
    let title: String?
    let bounds: [Int]
    let active: Bool
    let focused: Bool
    let rootRequested: Bool
    let root: HelperNode?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        layer = try c.decodeIfPresent(Int.self, forKey: .layer) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
        bounds = try c.decodeIfPresent([Int].self, forKey: .bounds) ?? []
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        rootRequested = c.contains(.root)
        root = try c.decodeIfPresent(HelperNode.self, forKey: .root)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, layer, title, bounds, active, focused, root
    }
}

struct HelperDump: Decodable, Equatable, Sendable {
    let generation: Int
    /// False when the screen did not settle within the request's idle timeout.
    let idle: Bool
    /// The event log's sequence number, read before the walk.
    let eventSeq: Int64
    let display: HelperDisplay
    let windows: [HelperWindow]
    /// The helper stopped at 20,000 nodes or depth 200.
    let truncated: Bool

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decode(Int.self, forKey: .generation)
        idle = try c.decodeIfPresent(Bool.self, forKey: .idle) ?? true
        eventSeq = try c.decodeIfPresent(Int64.self, forKey: .eventSeq) ?? 0
        display = try c.decode(HelperDisplay.self, forKey: .display)
        windows = try c.decodeIfPresent([HelperWindow].self, forKey: .windows) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case generation, idle, eventSeq, display, windows, truncated
    }
}

/// The `setProgress` reply: the range as the node reads after the action, nil when it no longer reports one.
struct HelperProgressResult: Decodable, Equatable, Sendable {
    let range: HelperRange?
}

/// One accessibility event the helper kept: window and content changes, focus, clicks and scrolls, but not the status bar.
struct HelperEvent: Decodable, Equatable, Sendable {
    let seq: Int64
    let type: Int
    let package: String?
    let windowId: Int?
}

/// The `events` reply: the events after the request's `since`, oldest first, at most 64.
struct HelperEvents: Decodable, Equatable, Sendable {
    let events: [HelperEvent]
    let eventSeq: Int64?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([HelperEvent].self, forKey: .events) ?? []
        eventSeq = try c.decodeIfPresent(Int64.self, forKey: .eventSeq)
    }

    private enum CodingKeys: String, CodingKey {
        case events, eventSeq
    }
}

/// The `setText` reply: the field that took the text and its new length in UTF-16 units (nil for passwords).
struct HelperTextResult: Decodable, Equatable, Sendable {
    let className: String?
    let resourceId: String?
    let length: Int?
}

/// The `display` op's reply: the display and the window list without trees.
struct HelperDisplayReply: Decodable, Equatable, Sendable {
    let display: HelperDisplay
    let windows: [HelperWindow]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decode(HelperDisplay.self, forKey: .display)
        windows = try c.decodeIfPresent([HelperWindow].self, forKey: .windows) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case display, windows
    }
}
