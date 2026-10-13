import Foundation
import OffsiderCore

/// Runs device shell scripts on one emulator; a non-zero `input` status is an error.
struct AdbDeviceShell: Sendable {
    let client: AdbClient
    let serial: String

    /// A `redactedLabel` names the script in errors and logs instead of the script itself, and hides its output.
    func run(_ script: String, waiting seconds: TimeInterval = 0, redactedLabel: String? = nil) async throws {
        let timeout = Duration.seconds(15) + .milliseconds(Int((seconds * 1000).rounded(.up)))
        let label = redactedLabel ?? (script.count > 120 ? String(script.prefix(117)) + "..." : script)
        let result = try await client.shell(script, on: serial, timeout: timeout, label: label)
        guard result.status == 0 else {
            let message = redactedLabel == nil
                ? (result.stderrText + result.stdoutText).split(whereSeparator: \.isNewline).first.map(String.init)
                : nil
            throw AndroidError.inputFailed(serial: serial, detail: message ?? "`\(redactedLabel ?? "input")` exited \(result.status)")
        }
    }
}

enum AndroidInputExecutor: Sendable {
    case adb(AdbDeviceShell)
    case grpc(GrpcInputDriver)
    case helper(HelperInputDriver)
}

/// How `type --replace` went: the helper set the text, or the session must clear the field with keys and type.
enum TextReplacement: Equatable, Sendable {
    case replaced
    /// The helper set the text, but the field reports fewer characters, as a field with a length or character filter does.
    case replacedWrongLength(field: AndroidFieldInfo?)
    case useKeys(warning: String?, field: AndroidFieldInfo? = nil)
}

/// The focused field as the screen shows it, after keys replaced its text.
struct FocusedFieldReading: Equatable, Sendable {
    /// Empty while the field shows its hint; nil for a password field.
    var text: String?
    var secure: Bool
    /// Its class and id, without `inputType`.
    var field: AndroidFieldInfo
}

/// How input reaches one emulator in this command: its executor, the display scale and the clipboard endpoint.
struct AndroidInputRoute {
    let executor: AndroidInputExecutor
    let scale: Double
    /// The gRPC endpoint for the clipboard, even when a resized display keeps other input on adb.
    let clipboard: (any EmulatorControlling)?
    /// Why there is no gRPC endpoint, for the error when text needs a paste.
    let adbReason: AdbReason
    /// Where keys, buttons and text go when the executor's never arrive (gRPC on an AVD without a hardware keyboard).
    var keys: AndroidInputExecutor? = nil
}

/// One command's input on one emulator; keeps finger state so a failed gesture can be lifted on close.
@MainActor
final class AndroidInputSession: InputSession, TextInputSession {
    let device: DeviceID
    /// adb is always there, whatever carries the input.
    private let shell: AdbDeviceShell
    /// Read on first input, so a replacement the helper completes needs no display probe or transport.
    private let resolveRoute: @MainActor () async throws -> AndroidInputRoute
    private var resolvedRoute: AndroidInputRoute?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Looked up only when a message needs it, so ordinary input costs no extra adb call.
    private let avdName: @MainActor () async -> String?
    private let replaceFocusedText: @MainActor (String) async throws -> TextReplacement
    /// Read only before a paste, the one path that puts text on a clipboard.
    private let focusedSecureField: @MainActor () async -> Bool
    /// The focused field after a key replacement; nil when it cannot be read.
    private let readFocusedField: @MainActor () async -> FocusedFieldReading?
    /// The helper's `paste` op on the focused field, refused unless it is the given one; nil when the helper has none.
    private let pasteFocused: @MainActor (AndroidFieldInfo) async throws -> HelperTextResult?
    private let log: AndroidLog
    private let timing: AndroidTiming
    private var touchIsDown = false
    private var lastTouch: AndroidPoint?
    /// Fingers of a multi-finger touch still down, lifted on close after a failure.
    private var heldFingers: [AndroidPoint] = []
    /// The helper for multi-finger input when the route is `input`, which moves one finger; nil when the policy forbids it.
    private let multiTouchHelper: @MainActor () async throws -> HelperInputDriver?
    /// The helper for a key combination `input` would drop (before Android 12); nil when `input` sends it, and throws when nothing can.
    private let keyCombinationHelper: @MainActor () async throws -> HelperInputDriver?

    init(
        device: DeviceID,
        shell: AdbDeviceShell,
        route: @escaping @MainActor () async throws -> AndroidInputRoute,
        avdName: @escaping @MainActor () async -> String?,
        replaceFocusedText: @escaping @MainActor (String) async throws -> TextReplacement,
        focusedSecureField: @escaping @MainActor () async -> Bool = { false },
        multiTouchHelper: @escaping @MainActor () async throws -> HelperInputDriver? = { nil },
        keyCombinationHelper: @escaping @MainActor () async throws -> HelperInputDriver? = { nil },
        readFocusedField: @escaping @MainActor () async -> FocusedFieldReading? = { nil },
        pasteFocused: @escaping @MainActor (AndroidFieldInfo) async throws -> HelperTextResult? = { _ in nil },
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        log: @escaping AndroidLog,
        timing: AndroidTiming = .disabled
    ) {
        self.device = device
        self.shell = shell
        self.resolveRoute = route
        self.avdName = avdName
        self.replaceFocusedText = replaceFocusedText
        self.focusedSecureField = focusedSecureField
        self.multiTouchHelper = multiTouchHelper
        self.keyCombinationHelper = keyCombinationHelper
        self.readFocusedField = readFocusedField
        self.pasteFocused = pasteFocused
        self.sleep = sleep
        self.log = log
        self.timing = timing
    }

    private func route() async throws -> AndroidInputRoute {
        if let resolvedRoute {
            return resolvedRoute
        }
        let route = try await resolveRoute()
        resolvedRoute = route
        return route
    }

    /// The emulator syncs its clipboard into the guest asynchronously, and the app reads it after the paste key.
    static let clipboardSyncWait = Duration.milliseconds(150)
    static let pasteReadWait = Duration.milliseconds(300)
    static let pasteKeyCode = 279

    func perform(_ event: InputEvent) async throws {
        try await timing.measure(.input) {
            try await dispatch(event)
        }
    }

    /// Through the helper, down, hold and up are one `inject`; elsewhere, the shared timed down and up.
    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        guard case .helper = try await route().executor else {
            try await separatePhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay)
            return
        }
        if let preDelay, preDelay > 0 {
            try await sleep(.seconds(preDelay))
        }
        try await perform(.composite([
            .touch(direction: .down, x: point.x, y: point.y),
            .delay(TapTiming.defaultHoldDuration),
            .touch(direction: .up, x: point.x, y: point.y),
        ]))
        if let postDelay, postDelay > 0 {
            try await sleep(.seconds(postDelay))
        }
    }

    /// The `InputSession` default: after a failure that follows the down, only a best-effort up, never a second down.
    private func separatePhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        if let preDelay, preDelay > 0 {
            try await Task.sleep(for: .seconds(preDelay))
        }
        let up = InputEvent.touch(direction: .up, x: point.x, y: point.y)
        var didTouchDown = false
        do {
            try await perform(.touch(direction: .down, x: point.x, y: point.y))
            didTouchDown = true
            try await Task.sleep(for: .seconds(TapTiming.defaultHoldDuration))
            try await perform(up)
            didTouchDown = false
        } catch {
            if didTouchDown {
                try? await perform(up)
            }
            throw error
        }
        if let postDelay, postDelay > 0 {
            try await Task.sleep(for: .seconds(postDelay))
        }
    }

    private func dispatch(_ event: InputEvent) async throws {
        var route = try await route()
        var down = touchIsDown
        let steps = try AndroidInputLowering.steps(for: event, touchIsDown: &down, scale: route.scale)
        if case .adb = route.executor, let helper = try await helper(for: steps) {
            route = AndroidInputRoute(executor: .helper(helper), scale: route.scale, clipboard: route.clipboard, adbReason: route.adbReason)
            resolvedRoute = route
        } else if case .adb? = route.keys, AdbInputScript.hasKeyCombination(steps), let helper = try await keyCombinationHelper() {
            route.keys = .helper(helper)
            resolvedRoute = route
        }
        try await run(steps, through: route.executor, keys: route.keys)
        touchIsDown = down
    }

    /// The helper for steps `input` cannot send: several fingers, or a key combination it would drop.
    private func helper(for steps: [AndroidInputStep]) async throws -> HelperInputDriver? {
        if steps.contains(where: \.isMultiTouch) {
            return try await multiTouchHelper()
        }
        return AdbInputScript.hasKeyCombination(steps) ? try await keyCombinationHelper() : nil
    }

    /// All-ASCII text as key events (gRPC `text` chunks, or adb `input text`); anything else pasted whole.
    func typeText(_ text: String) async throws {
        try await timing.measure(.input) {
            try await dispatchText(text)
        }
    }

    private func dispatchText(_ text: String) async throws {
        let route = try await route()
        switch try AndroidTextPlan.make(for: text) {
        case .paste(let whole):
            guard let clipboard = route.clipboard else {
                throw AndroidError.grpcRequiredForText(serial: device.rawValue, avd: await avdName(), reason: route.adbReason)
            }
            if await focusedSecureField() {
                throw AndroidError.securePasteRefused(device.rawValue)
            }
            try await paste(whole, through: clipboard)
        case .keys(let chunks):
            let executor = route.keys ?? route.executor
            if case .grpc(let driver) = executor {
                try await type(chunks, on: driver.emulator)
                return
            }
            if case .helper(let driver) = executor {
                try await driver.type(chunks)
                return
            }
            let commands = try chunks.flatMap { chunk -> [String] in
                switch chunk {
                case .text(let run): return AdbShellQuoting.inputTextCommands(for: run)
                case .key(let usage): return ["input keyevent \(try AndroidKeyTable.requireKeyCode(for: usage))"]
                }
            }
            guard !commands.isEmpty else { return }
            try await shell.run(commands.joined(separator: " && "), redactedLabel: "input text (\(text.count) character\(text.count == 1 ? "" : "s"))")
        }
    }

    /// One accessibility action, then Return for a trailing newline; without it, Ctrl+A, Delete and the text as keys.
    func replaceText(_ text: String) async throws {
        let submits = text.hasSuffix("\n")
        switch try await replaceFocusedText(submits ? String(text.dropLast()) : text) {
        case .replaced:
            if submits {
                try await typeText("\n")
            }
        case .replacedWrongLength(let field):
            try await confirmReplacement(submits ? String(text.dropLast()) : text, field: field)
            if submits {
                try await typeText("\n")
            }
        case .useKeys(let warning, let field):
            if let warning {
                log(.warning, warning)
            }
            try await perform(InputEvent.selectAllAndDelete(modifier: InputEvent.controlKey))
            if !text.isEmpty {
                try await typeText(text)
            }
            if !submits {
                try await confirmReplacement(text, field: field)
            }
        }
    }

    /// After keys (or a set-text the field cut short) replaced a field: when it reads shorter than the text (a longer reading is formatting),
    /// paste the text over that field alone, never a password field; anything but the exact text afterwards is `text_not_accepted`.
    private func confirmReplacement(_ text: String, field: AndroidFieldInfo?) async throws {
        let expected = text.utf16.count
        guard let reading = await readFocusedField(), !reading.secure, let shown = reading.text, shown.utf16.count < expected else { return }
        log(.debug, "The focused field on \(device.rawValue) holds \(shown.utf16.count) characters after typing \(expected)")
        let target = field.map { AndroidFieldInfo(className: $0.className, resourceId: $0.resourceId) } ?? reading.field
        var pasted = false
        if let clipboard = try await route().clipboard {
            let saved = try await clipboard.clipboard()
            try await clipboard.setClipboard(text)
            do {
                try await sleep(Self.clipboardSyncWait)
                pasted = try await pasteFocused(target) != nil
                if pasted { try await sleep(Self.pasteReadWait) }
            } catch {
                await restoreClipboard(saved, on: clipboard)
                throw error
            }
            await restoreClipboard(saved, on: clipboard)
            if pasted, let again = await readFocusedField(), again.field == target, again.text == text {
                return
            }
        }
        throw AndroidError.textNotAccepted(device.rawValue, field: field, pasted: pasted)
    }

    private func type(_ chunks: [AndroidTextPlan.Chunk], on emulator: any EmulatorControlling) async throws {
        for chunk in chunks {
            switch chunk {
            case .text(let run):
                try await emulator.sendKey(.text(run))
            case .key(let usage):
                guard let key = AndroidKeyTable.grpcKey(for: usage, phase: .press) else { throw AndroidError.unsupportedKey(usage) }
                try await emulator.sendKey(key)
            }
        }
    }

    /// Save the clipboard, set the text, let it sync, paste over adb, let the app read it, then restore, on failure too.
    private func paste(_ text: String, through emulator: any EmulatorControlling) async throws {
        let saved = try await emulator.clipboard()
        try await emulator.setClipboard(text)
        do {
            try await sleep(Self.clipboardSyncWait)
            try await shell.run("input keyevent \(Self.pasteKeyCode)")
            try await sleep(Self.pasteReadWait)
        } catch {
            await restoreClipboard(saved, on: emulator)
            throw error
        }
        await restoreClipboard(saved, on: emulator)
    }

    private func restoreClipboard(_ saved: String, on emulator: any EmulatorControlling) async {
        do {
            try await emulator.setClipboard(saved)
        } catch {
            log(.warning, "Could not restore the emulator's clipboard after pasting: \((error as? AndroidError)?.message ?? error.localizedDescription)")
        }
    }

    func close() async {
        await liftHeldFingers()
        guard touchIsDown, let point = lastTouch, let route = resolvedRoute else { return }
        touchIsDown = false
        do {
            switch route.executor {
            case .adb(let shell):
                try await shell.run("input motionevent UP \(Int(point.x.rounded())) \(Int(point.y.rounded()))")
            case .grpc(let driver):
                try await driver.touch(point, down: false)
            case .helper(let driver):
                try await driver.lift(at: point)
            }
        } catch {
            log(.warning, "Could not lift the touch left down on \(device.rawValue): \(error.localizedDescription)")
        }
    }

    private func liftHeldFingers() async {
        guard !heldFingers.isEmpty, let route = resolvedRoute else { return }
        let fingers = heldFingers
        heldFingers = []
        do {
            switch route.executor {
            case .adb: return
            case .grpc(let driver): try await driver.touches(fingers, down: false)
            case .helper(let driver): try await driver.run([.touches(.up, fingers)])
            }
        } catch {
            log(.warning, "Could not lift the fingers left down on \(device.rawValue): \(error.localizedDescription)")
        }
    }

    private func run(_ steps: [AndroidInputStep], through executor: AndroidInputExecutor, keys: AndroidInputExecutor? = nil) async throws {
        if let last = steps.last(where: { if case .touch = $0 { return true } else { return false } }), case .touch(_, let point) = last {
            lastTouch = point
        }
        let pressesDown = steps.contains { if case .touch(.down, _) = $0 { return true } else { return false } }
        let parts = try Self.parts(of: steps, through: executor, keys: keys)
        let fingersBefore = heldFingers
        for step in steps {
            if case .touches(let phase, let points) = step {
                heldFingers = phase == .up ? [] : points
            }
        }
        do {
            for part in parts {
                switch part.executor {
                case .adb(let shell):
                    let wait = AdbInputScript.waitTime(of: part.steps)
                    for script in part.scripts {
                        try await shell.run(script, waiting: wait)
                    }
                case .grpc(let driver):
                    try await driver.run(part.steps)
                case .helper(let driver):
                    try await driver.run(part.steps)
                }
            }
        } catch {
            if case .helper(let driver) = executor, driver.releasedInput {
                touchIsDown = false
                heldFingers = []
            } else {
                if pressesDown {
                    touchIsDown = true
                }
                heldFingers = steps.lazy.compactMap(\.fingersDown).first ?? fingersBefore
            }
            throw error
        }
    }
}

extension AndroidInputSession {
    /// Each run of steps with the executor that sends it, and its `input` scripts when that is adb, built before anything is sent.
    private static func parts(
        of steps: [AndroidInputStep],
        through executor: AndroidInputExecutor,
        keys: AndroidInputExecutor?
    ) throws -> [(executor: AndroidInputExecutor, steps: [AndroidInputStep], scripts: [String])] {
        let runs = keys == nil ? [(keys: false, steps: steps)] : AndroidInputStep.keyRuns(steps)
        return try runs.map { run in
            let target = run.keys ? keys ?? executor : executor
            guard case .adb = target else { return (target, run.steps, []) }
            return (target, run.steps, try AdbInputScript.scripts(for: run.steps))
        }
    }
}

extension AndroidInputStep {
    var isKeyOrButton: Bool {
        switch self {
        case .key, .button: return true
        default: return false
        }
    }

    /// Steps cut where they switch between keys or buttons and anything else; a pause stays with the steps before it.
    static func keyRuns(_ steps: [AndroidInputStep]) -> [(keys: Bool, steps: [AndroidInputStep])] {
        var runs: [(keys: Bool, steps: [AndroidInputStep])] = []
        for step in steps {
            let isPause = if case .pause = step { true } else { false }
            if let last = runs.indices.last, isPause || runs[last].keys == step.isKeyOrButton {
                runs[last].steps.append(step)
            } else {
                runs.append((step.isKeyOrButton, [step]))
            }
        }
        return runs
    }

    var isMultiTouch: Bool {
        if case .touches = self { return true }
        return false
    }

    var fingersDown: [AndroidPoint]? {
        if case .touches(.down, let points) = self { return points }
        return nil
    }
}
