import FBSimulatorControl
import Foundation
import OffsiderCore

/// One request on a command's connection, a newline-ended JSON object; the connection lasts the command's input session.
struct HIDBrokerRequest: Codable, Equatable {
    enum Op: String, Codable {
        case input
        case status
        case stop
    }

    let op: Op
    var event: HIDBrokerEvent?
    /// Touches stay down once the request ends: `touch --down` now, `--up` in a later command.
    var keepHeld: Bool?
    /// The command's `OFFSIDER_HID_STABILIZATION_MS`, slept after the event.
    var stabilizationMs: UInt64?
    /// The command's `OFFSIDER_SIMULATOR_SESSION_IDLE`; the latest command's setting wins.
    var idleSeconds: Int?
}

struct HIDBrokerReply: Codable, Equatable {
    var error: String?
    var status: HIDBrokerStatus?
    /// The broker refused before sending anything, so the input may go another way.
    var notSent: Bool?
}

/// The `status` reply, read without counting as use.
struct HIDBrokerStatus: Codable, Equatable {
    let udid: String
    let pid: Int32
    /// Seconds since 1970.
    let startedAt: Double
    let idleSeconds: Int
    /// Seconds since the last command's input or disconnect.
    let idleFor: Int
    /// Other commands connected, which a stop would cut off.
    let attached: Int
    /// `ready`, or `stopping` while it finishes.
    var state: String? = nil
}

/// An `FBSimulatorHIDEvent` of the kinds input commands send, as compact arrays: `["t", true, x, y]` is a touch down.
struct HIDBrokerEvent: Codable, Equatable {
    static let maxDepth = 16
    static let maxPrimitives = 65_536

    let hid: FBSimulatorHIDEvent

    init(_ hid: FBSimulatorHIDEvent) {
        self.hid = hid
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch hid {
        case let .touch(direction, x, y):
            try container.encode("t")
            try container.encode(direction == .down)
            try container.encode(x)
            try container.encode(y)
        case let .twoFingerTouch(direction, first, second):
            try container.encode("f")
            try container.encode(direction == .down)
            try container.encode([Double(first.x), Double(first.y), Double(second.x), Double(second.y)])
        case let .button(direction, button):
            try container.encode("b")
            try container.encode(direction == .down)
            try container.encode(button.rawValue)
        case let .keyboard(direction, keyCode):
            try container.encode("k")
            try container.encode(direction == .down)
            try container.encode(keyCode)
        case let .delay(seconds):
            try container.encode("w")
            try container.encode(seconds)
        case let .composite(events):
            try container.encode("c")
            for event in events {
                try container.encode(HIDBrokerEvent(event))
            }
        case .deviceOrientation, .shake, .toggleInCallStatusBar, .lockDevice:
            throw EncodingError.invalidValue(hid, .init(codingPath: encoder.codingPath, debugDescription: "The broker carries touches, buttons, keys and pauses only."))
        @unknown default:
            throw EncodingError.invalidValue(hid, .init(codingPath: encoder.codingPath, debugDescription: "The broker carries touches, buttons, keys and pauses only."))
        }
    }

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= Self.maxDepth else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Events nest too deep."))
        }
        var container = try decoder.unkeyedContainer()
        let tag = try container.decode(String.self)
        func direction() throws -> FBSimulatorHIDDirection {
            try container.decode(Bool.self) ? .down : .up
        }
        switch tag {
        case "t":
            hid = .touch(direction: try direction(), x: try container.decode(Double.self), y: try container.decode(Double.self))
        case "f":
            let down = try direction()
            let points = try container.decode([Double].self)
            guard points.count == 4 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Two fingers need four coordinates."))
            }
            hid = .twoFingerTouch(direction: down, finger1: CGPoint(x: points[0], y: points[1]), finger2: CGPoint(x: points[2], y: points[3]))
        case "b":
            let down = try direction()
            let raw = try container.decode(Int32.self)
            guard let button = FBSimulatorHIDButton(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown button \(raw)."))
            }
            hid = .button(direction: down, button: button)
        case "k":
            hid = .keyboard(direction: try direction(), keyCode: try container.decode(UInt32.self))
        case "w":
            hid = .delay(try container.decode(Double.self))
        case "c":
            var events: [FBSimulatorHIDEvent] = []
            while !container.isAtEnd {
                events.append(try container.decode(HIDBrokerEvent.self).hid)
            }
            hid = .composite(events)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown event \(tag)."))
        }
    }
}

extension HIDBrokerEvent {
    struct Summary: Equatable {
        var primitives = 0
        var delaySeconds = 0.0
        var keyboardEvents = 0
    }

    /// Refuses, before anything is sent: too many primitives (unless `limitingCount` is false), a coordinate that is not finite or within ±100,000, a pause outside 0 to 3600 s, or pauses over 3600 s together.
    @discardableResult
    static func validate(_ event: FBSimulatorHIDEvent, limitingCount: Bool = true) throws -> Summary {
        var summary = Summary()
        func refuse(_ detail: String) -> CLIError {
            CLIError(errorDescription: "Refused simulator input: \(detail). Nothing was sent.", reason: .hidBrokerFailed)
        }
        func check(_ values: Double...) throws {
            guard values.allSatisfy({ $0.isFinite && abs($0) <= InputEvent.coordinateLimit }) else {
                throw refuse("a coordinate is not finite or within ±\(Int(InputEvent.coordinateLimit))")
            }
        }
        func visit(_ event: FBSimulatorHIDEvent) throws {
            switch event {
            case let .touch(_, x, y):
                try check(x, y)
            case let .twoFingerTouch(_, first, second):
                try check(Double(first.x), Double(first.y), Double(second.x), Double(second.y))
            case .keyboard:
                summary.keyboardEvents += 1
            case .button:
                break
            case let .delay(seconds):
                guard seconds.isFinite, (0...InputEvent.durationLimit).contains(seconds) else {
                    throw refuse("a pause of \(seconds) s is not between 0 and \(Int(InputEvent.durationLimit)) s")
                }
                summary.delaySeconds += seconds
            case let .composite(events):
                for event in events { try visit(event) }
                return
            case .deviceOrientation, .shake, .toggleInCallStatusBar, .lockDevice:
                throw refuse("the broker carries touches, buttons, keys and pauses only")
            @unknown default:
                throw refuse("the broker carries touches, buttons, keys and pauses only")
            }
            summary.primitives += 1
            guard !limitingCount || summary.primitives <= maxPrimitives else {
                throw refuse("more than \(maxPrimitives) events in one request")
            }
        }
        try visit(event)
        guard summary.delaySeconds <= InputEvent.durationLimit else {
            throw refuse("pauses add up to more than \(Int(InputEvent.durationLimit)) s")
        }
        return summary
    }

    /// Keys and buttons need idb's own pacing and drain, so such an event is sent whole; touches and pauses are sent one by one.
    static func isPaced(_ event: FBSimulatorHIDEvent) -> Bool {
        switch event {
        case .keyboard, .button: return true
        case let .composite(events): return events.contains(where: isPaced)
        default: return false
        }
    }

    /// The touches, two-finger touches and pauses of a touch-only event, in order.
    static func steps(_ event: FBSimulatorHIDEvent) -> [FBSimulatorHIDEvent] {
        if case let .composite(events) = event { return events.flatMap(steps) }
        return [event]
    }
}

/// What one connection has left down, lifted when it goes.
struct HIDHeldInput: Equatable {
    struct Point: Equatable {
        let x: Double
        let y: Double
    }

    var touch: Point?
    var fingers: [Point]?
    var buttons: Set<Int32> = []
    var keys: Set<UInt32> = []

    var isEmpty: Bool {
        touch == nil && fingers == nil && buttons.isEmpty && keys.isEmpty
    }

    /// The state after `event` played in full.
    mutating func apply(_ event: FBSimulatorHIDEvent) {
        visit(event, includeUps: true)
    }

    /// Adds everything `event` presses, for an event that stopped part way.
    mutating func include(_ event: FBSimulatorHIDEvent) {
        visit(event, includeUps: false)
    }

    private mutating func visit(_ event: FBSimulatorHIDEvent, includeUps: Bool) {
        switch event {
        case let .touch(direction, x, y):
            if direction == .down { touch = Point(x: x, y: y) } else if includeUps { touch = nil }
        case let .twoFingerTouch(direction, first, second):
            if direction == .down {
                fingers = [Point(x: Double(first.x), y: Double(first.y)), Point(x: Double(second.x), y: Double(second.y))]
            } else if includeUps {
                fingers = nil
            }
        // idb sends Apple Pay as two whole side-button presses, so it is never left down.
        case let .button(direction, button) where button != .applePay:
            if direction == .down { buttons.insert(button.rawValue) } else if includeUps { buttons.remove(button.rawValue) }
        case let .keyboard(direction, keyCode):
            if direction == .down { keys.insert(keyCode) } else if includeUps { keys.remove(keyCode) }
        case let .composite(events):
            for event in events { visit(event, includeUps: includeUps) }
        default:
            break
        }
    }

    /// One event lifting everything held: keys, buttons, then fingers; nil when nothing is.
    var release: FBSimulatorHIDEvent? {
        var events: [FBSimulatorHIDEvent] = keys.sorted().map { .keyboard(direction: .up, keyCode: $0) }
        events += buttons.sorted().compactMap { FBSimulatorHIDButton(rawValue: $0).map { .button(direction: .up, button: $0) } }
        if let fingers, fingers.count == 2 {
            events.append(.twoFingerTouch(direction: .up, finger1: CGPoint(x: fingers[0].x, y: fingers[0].y), finger2: CGPoint(x: fingers[1].x, y: fingers[1].y)))
        }
        if let touch {
            events.append(.touch(direction: .up, x: touch.x, y: touch.y))
        }
        return events.isEmpty ? nil : .composite(events)
    }
}
