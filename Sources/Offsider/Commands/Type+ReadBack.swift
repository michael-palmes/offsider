import Foundation
import OffsiderCore

/// Reads one text field between keys: through an element kept open, else through a slower read of its own each time.
@MainActor
final class FieldReader {
    private var watch: (any ElementWatch)?
    private let initial: String?
    private let tree: @MainActor () async -> UINode?
    /// True once the kept element has shown a text other than its first, which a stale one never does.
    private(set) var moved = false

    init(watch: (any ElementWatch)?, initial: String? = nil, tree: @escaping @MainActor () async -> UINode?) {
        self.watch = watch
        self.initial = initial
        self.tree = tree
    }

    /// True while a read is one short round trip, so each key can wait for it.
    var live: Bool { watch != nil }

    func read() async -> UINode? {
        if let node = await watch?.read() {
            if node.value != initial { moved = true }
            return node
        }
        close()
        return await tree()
    }

    /// The field from a read of its own, which a kept element that went stale cannot contradict; the element is dropped when they disagree.
    func fresh() async -> UINode? {
        let node = await tree()
        if let watch, await watch.read()?.value != node?.value { close() }
        return node
    }

    func close() {
        watch?.close()
        watch = nil
    }
}

/// The element with keyboard focus on a USB iPhone or iPad, while it is still the field the keys went to.
@MainActor
final class FocusedFieldWatch: ElementWatch {
    private let backend: any FocusedElementReading
    private let device: DeviceID
    private let field: UINode

    init(backend: any FocusedElementReading, device: DeviceID, field: UINode) {
        self.backend = backend
        self.device = device
        self.field = field
    }

    func read() async -> UINode? {
        guard let focused = try? await backend.focusedElement(on: device), TypedExpectation.isSameField(focused, field) else { return nil }
        return focused
    }

    func close() {}
}

extension Type {
    /// How long a field that took some of the text may go without changing before it is typed again.
    static let heldTimeout: TimeInterval = 1
    /// The longest a field that keeps changing is waited for.
    static let settleLimit: TimeInterval = 10
    /// How long a value that says nothing either way may go without changing before it passes.
    static let unjudgedTimeout: TimeInterval = 0.3
    /// How long one key may take to show in the field before it is pressed once more.
    static let keyTimeout: TimeInterval = 0.5
    static let keyPoll: Duration = .milliseconds(10)

    /// What became of the clear `--replace` sends before its keys.
    enum Cleared: Equatable {
        /// No clear went on its own.
        case none
        /// Sent, and the field's text had not changed by the time the keys went.
        case unseen
        /// The field's text once the clear showed, which an empty React Native field reads as its placeholder.
        case seen(String)
    }

    /// What a field holds once it stops changing after the keys.
    enum Landing: Equatable {
        /// The text sent, or nothing a read can judge.
        case held
        case unchanged
        /// Changed, but not to the text sent; the value is never printed.
        case differs(String)
    }

    /// Before the keys go to an iOS simulator: the reader `confirmHeld` judges them with; nil when nothing will be judged. A password field is never read. A React Native app's field, a UIKit view whose element stays live, is hit-tested now, while it is idle and the hit-test is quickest; another app's is read from the tree after the keys, as a SwiftUI field's kept element goes stale.
    @MainActor
    func fieldReader(for inputText: String, focus: FocusCheck, backend: any DeviceBackend, device: DeviceID, watching: Bool? = nil) async -> FieldReader? {
        guard device.platform == .ios, !device.isPhysicalIOSDevice, readBackTarget(inputText, focus: focus) != nil else { return nil }
        let typed = landingExpectation(inputText, focus: focus, replacing: replace)
        let watching = watching ?? ReactNativeBundle.isFront(in: focus.tree)
        return await Timings.measure("type-read-back") { await Self.fieldReader(typed, focus: focus, backend: backend, device: device, watching: watching) }
    }

    /// Keys on a USB iPhone or iPad, read back as `confirmHeld` reads a simulator's, through the runner's read of the one element with keyboard focus. Nothing is read when the text went through the runner, when the field is not a text field the focus check listed, or when it may be a password field.
    @MainActor
    func confirmHeldOnDevice(
        _ inputText: String, focus: FocusCheck, backend: any DeviceBackend, device: DeviceID, clock: PollClock = .live,
        warn: @MainActor (String) -> Void = { Console.current.notice(.warning(InputPersonView.sentence($0), agent: $0)) },
        send: (@MainActor (InputEvent) async throws -> Void)?
    ) async throws {
        guard device.isPhysicalIOSDevice, focus.secure != .unknown, readBackTarget(inputText, focus: focus) != nil,
              let field = focus.field, field.role.isTextInput, !field.isSecure,
              let reading = backend as? any FocusedElementReading, await reading.typesWithKeys(inputText, on: device) else { return }
        let typed = landingExpectation(inputText, focus: focus, replacing: replace)
        let reader = FieldReader(watch: FocusedFieldWatch(backend: reading, device: device, field: field), initial: field.value) {
            guard let tree = try? await backend.accessibilityTree(for: device) else { return nil }
            return typed.locate(in: tree)
        }
        try await Timings.measure("type-read-back") {
            try await confirmHeld(inputText, focus: focus, reader: reader, backend: backend, device: device, clock: clock, warn: warn, send: send)
        }
    }

    /// The field a read-back names, when its text can be judged: never a password, text ending in Return, text too long to read whole, or the text the field already held.
    private func readBackTarget(_ inputText: String, focus: FocusCheck) -> String? {
        guard landingExpectation(inputText, focus: focus, replacing: replace).judged, inputText.count <= TypedText.longest,
              inputText.contains(where: { !$0.isWhitespace }) else { return nil }
        // A field that selects its text on focus ends unchanged when typed the same text.
        guard replace || (focus.field?.value ?? "") != inputText else { return nil }
        return namedField ?? Self.focusedTarget(focus.field)
    }

    /// The text's keys to an iOS simulator. With `--replace` and a field one quick read shows, the clear goes first and the keys follow as soon as the field shows it, in place of the fixed pause.
    @MainActor
    func sendKeys(
        _ inputText: String, paced: Bool, reader: FieldReader?, clock: PollClock, send: @MainActor (InputEvent) async throws -> Void
    ) async throws -> Cleared {
        guard replace, !inputText.isEmpty, let reader, reader.live, let was = await reader.read() else {
            try await send(.composite(try Self.iosEvents(for: inputText, replacing: replace, paced: paced)))
            return .none
        }
        try await send(InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey))
        let cleared = try await Self.change(from: was.value ?? "", reader: reader, within: InputEvent.iosClearSettle, clock: clock)
        try await send(.composite(try Self.iosEvents(for: inputText, replacing: false, paced: paced)))
        return cleared.map { .seen($0.value ?? "") } ?? .unseen
    }

    /// The field once its text is no longer `value`; nil when `limit` passes first or a quick read can no longer show it.
    @MainActor
    private static func change(from value: String, reader: FieldReader, within limit: TimeInterval, clock: PollClock) async throws -> UINode? {
        let deadline = clock.now() + limit
        while reader.live, let now = await reader.read() {
            if (now.value ?? "") != value { return now }
            guard clock.now() < deadline else { break }
            try await clock.sleep(keyPoll)
        }
        return nil
    }

    /// Keys on an iOS simulator, read back from the field they went to: text that changed it but is not all there, in order, is typed once more, each key waiting until the field holds it, and what still differs exits 5.
    @MainActor
    func confirmHeld(
        _ inputText: String, focus: FocusCheck, reader: FieldReader?, cleared: Cleared = .none, backend: any DeviceBackend, device: DeviceID, clock: PollClock,
        warn: @MainActor (String) -> Void = { Console.current.notice(.warning(InputPersonView.sentence($0), agent: $0)) },
        send: (@MainActor (InputEvent) async throws -> Void)?
    ) async throws {
        guard let reader, let target = readBackTarget(inputText, focus: focus) else { return }
        defer { reader.close() }
        let typed = landingExpectation(inputText, focus: focus, replacing: replace)
        let before = focus.field?.value
        switch try await Self.landing(typed, before: before, cleared: cleared, reader: reader, clock: clock) {
        case .held:
            return
        case .unchanged:
            throw Self.textNotLandedRefusal(keyboard: nil, target: target, device: device)
        case .differs(let value):
            guard let clear = retypeClear(inputText, before: before, value: value) else {
                throw Self.textNotHeldRefusal(target: target, device: device, retyped: false)
            }
            let landed = try await Timings.measure("type-retype") {
                try await Self.sending(send, backend: backend, device: device) { send in
                    let base = try await Self.clearForRetype(clear, value: value, reader: reader, clock: clock, send: send)
                    // A formatter can take more than the Backspaces asked for, and typing on would build on text that is no longer the app's.
                    if !replace, try await !Self.restored(to: before, reader: reader, clock: clock) {
                        throw Self.textNotHeldRefusal(target: target, device: device, retyped: false)
                    }
                    try await Self.typePaced(inputText, replacing: replace, base: base, reader: reader, clock: clock, send: send)
                    return try await Self.landing(typed, before: replace ? before : base, reader: reader, clock: clock)
                }
            }
            guard landed == .held else { throw Self.textNotHeldRefusal(target: target, device: device, retyped: true) }
            warn("\(target) did not hold the text the first time, so Offsider typed it again.")
        }
    }

    /// `send` when the caller has a session open, as a batch does; else one session for `body`.
    @MainActor
    static func sending<T>(
        _ send: (@MainActor (InputEvent) async throws -> Void)?, backend: any DeviceBackend, device: DeviceID,
        _ body: @MainActor (@MainActor (InputEvent) async throws -> Void) async throws -> T
    ) async throws -> T {
        if let send { return try await body(send) }
        return try await backend.withTrackedSession(for: device) { session in try await body { try await session.perform($0) } }
    }

    /// The field through one hit-test a read, or a tree read when that does not answer with the field; with `watching`, through an element kept open at its centre when that element is the field.
    @MainActor
    static func fieldReader(_ typed: TypedExpectation, focus: FocusCheck, backend: any DeviceBackend, device: DeviceID, watching: Bool) async -> FieldReader {
        let gaps = focus.tree?.filledFromGaps != nil
        let tree: @MainActor () async -> UINode? = {
            if let tester = backend as? any PointHitTesting, let field = focus.field, field.role.isTextInput, let centre = field.frame?.center,
               let hit = (try? await tester.quickHitTest(at: centre, on: device)) ?? nil, TypedExpectation.isSameField(hit, field) {
                return hit
            }
            guard let plain = try? await backend.accessibilityTree(for: device) else { return nil }
            return typed.locate(in: gaps ? await backend.withGapsFilled(plain, on: device) : plain)
        }
        guard watching, let watcher = backend as? any ElementWatching, let field = focus.field, field.role.isTextInput, let centre = field.frame?.center,
              let watch = try? await watcher.watchElement(at: centre, on: device) else { return FieldReader(watch: nil, tree: tree) }
        guard let first = await watch.read(), TypedExpectation.isSameField(first, field) else {
            watch.close()
            return FieldReader(watch: nil, tree: tree)
        }
        return FieldReader(watch: watch, initial: first.value, tree: tree)
    }

    /// Polled while the field does not hold the text, as a busy app takes keys after the send returns: for `landingTimeout` while its text is as it was, or as the clear left it, else until it has gone `heldTimeout` without changing, and never past `settleLimit`. A value that says nothing either way passes after `unjudgedTimeout`, and a tree read has the last word before a miss.
    @MainActor
    static func landing(_ typed: TypedExpectation, before: String?, cleared: Cleared = .none, reader: FieldReader, clock: PollClock) async throws -> Landing {
        let start = clock.now()
        var confirmed = !reader.live
        var last: (value: String, at: TimeInterval)?
        while true {
            guard let now = await reader.read(), now.role.isTextInput, !now.isSecure else { return .held }
            let value = now.value ?? ""
            let unchanged = value == (before ?? "")
            let time = clock.now()
            // Text the clear has yet to remove shows the keys are still on their way, and what the clear left holds none of them.
            let idle = unchanged || cleared == .seen(value)
            let waiting = unchanged && cleared == .unseen && time - start < landingTimeout
            let check = waiting || cleared == .seen(value) ? .differs : judge(typed, before: before, field: now)
            guard check != .match else { return .held }
            if last?.value != value { last = (value, time) }
            if reader.moved { confirmed = true }
            let limit = idle ? landingTimeout : check == .unknown ? unjudgedTimeout : heldTimeout
            if (idle ? time - start : time - (last?.at ?? time)) < limit, time - start < settleLimit {
                // Reads any closer together hold up the keys the app has yet to take.
                try await clock.sleep(landingPoll)
            } else if check == .unknown {
                return .held
            } else if confirmed {
                return unchanged ? .unchanged : .differs(value)
            } else {
                confirmed = true
                guard let fresh = await reader.fresh(), fresh.role.isTextInput, !fresh.isSecure, judge(typed, before: before, field: fresh) == .differs else { return .held }
            }
        }
    }

    /// After `--replace` an empty field holds none of the text; plain text into a field that then empties itself, as one that takes it as a tag does, says nothing. Text with a key repeated, as a held key leaves it, is not the text sent.
    private static func judge(_ typed: TypedExpectation, before: String?, field: UINode) -> TextCheck {
        let value = field.value ?? ""
        if typed.replacing, value.isEmpty { return .differs }
        let check = typed.check(was: before, field: field)
        return check == .match && TypedText.repeatsKey(sent: typed.text, before: before, after: value, replacing: typed.replacing) ? .differs : check
    }

    /// The keys that take out what the first try left: the whole field for `--replace`, else only the characters the keys put there; nil when those cannot be told from what was there.
    func retypeClear(_ inputText: String, before: String?, value: String) -> InputEvent? {
        if replace { return InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey) }
        guard let own = TypedText.ownLength(sent: inputText, before: before, after: value) else { return nil }
        return .composite(Array(repeating: InputEvent.shortKeyPress(42), count: own))
    }

    /// Sends `clear` and waits until the field shows it; returns the field's text after it, which an empty React Native field reads as its placeholder.
    @MainActor
    static func clearForRetype(
        _ clear: InputEvent, value: String, reader: FieldReader, clock: PollClock, send: @MainActor (InputEvent) async throws -> Void
    ) async throws -> String? {
        guard clear != .composite([]) else { return value }
        try await send(clear)
        guard reader.live else {
            try await clock.sleep(.seconds(InputEvent.iosClearSettle))
            return nil
        }
        return try await change(from: value, reader: reader, within: keyTimeout, clock: clock)?.value
    }

    /// True once the field reads `before` again, or can no longer be read; false when `heldTimeout` passes first.
    @MainActor
    private static func restored(to before: String?, reader: FieldReader, clock: PollClock) async throws -> Bool {
        let deadline = clock.now() + heldTimeout
        while let now = await reader.read() {
            if (now.value ?? "") == (before ?? "") { return true }
            guard clock.now() < deadline else { return false }
            try await clock.sleep(reader.live ? keyPoll : landingPoll)
        }
        return true
    }

    /// One key at a time, each waiting until the field holds the text so far; a key that never shows is pressed once more, as the accent picker iOS opens for a key it takes as held swallows the next one. With no quick read, the keys go a fixed gap apart.
    @MainActor
    static func typePaced(
        _ text: String, replacing: Bool, base: String?, reader: FieldReader, clock: PollClock, send: @MainActor (InputEvent) async throws -> Void
    ) async throws {
        guard reader.live else {
            try await send(.composite(try iosEvents(for: text, replacing: false, paced: true)))
            return
        }
        var sent = ""
        for character in text {
            sent.append(character)
            let key = InputEvent.composite(try TextToHIDEvents.convertTextToHIDEvents(String(character)))
            let was = await reader.read()?.value
            try await send(key)
            if try await holds(sent, replacing: replacing, base: base, reader: reader, clock: clock) { continue }
            guard await reader.read()?.value == was else { continue }
            try await send(key)
            _ = try await holds(sent, replacing: replacing, base: base, reader: reader, clock: clock)
        }
    }

    /// True once the field holds `sent`, in order, or can no longer be read; false when `keyTimeout` passes first.
    @MainActor
    private static func holds(_ sent: String, replacing: Bool, base: String?, reader: FieldReader, clock: PollClock) async throws -> Bool {
        let deadline = clock.now() + keyTimeout
        while true {
            guard let now = await reader.read() else {
                try await clock.sleep(.seconds(reactNativeKeyGap))
                return true
            }
            if TypedText.judge(sent: sent, before: base, after: now.value ?? "", replacing: replacing) == .match { return true }
            guard clock.now() < deadline else { return false }
            try await clock.sleep(keyPoll)
        }
    }

    /// The field took keys but does not hold the text sent; the message names the field, never the text.
    @MainActor
    static func textNotHeldRefusal(target: String, device: DeviceID, retyped: Bool) -> CLIError {
        let what = retyped
            ? "Typed into \(target) twice, but it does not hold the text sent: the field cut or changed it, or keys were lost or repeated on the way. Read the field to see what it kept."
            : "Typed into \(target), but it does not hold the text sent, and what was there before could not be told from what was typed, or put back, so Offsider did not type again. Set the whole field with `offsider type --replace`."
        return CLIError(errorDescription: what, reason: .textNotAccepted, hint: CommandScope.current.describeHint(device: device.rawValue))
    }
}
