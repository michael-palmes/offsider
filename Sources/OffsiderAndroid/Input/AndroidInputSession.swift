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

/// Whether a password field has focus, read before text could reach a clipboard or an `input text` argument.
enum FocusedSecureField: Equatable, Sendable {
    case secure
    case notSecure
    /// The screen could not be read.
    case unknown
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
    /// Read before a paste, and before `input text` on an adb route.
    private let focusedSecureField: @MainActor () async -> FocusedSecureField
    /// The helper for a password: started if needed, else `helper_unavailable`.
    private let secretHelper: @MainActor () async throws -> HelperInputDriver
    /// On a phone, refuses a browser or system app in front; checked before text and before the first other input.
    private let requireForeground: @MainActor () async throws -> Void
    private var foregroundChecked = false
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

    init(
        device: DeviceID,
        shell: AdbDeviceShell,
        route: @escaping @MainActor () async throws -> AndroidInputRoute,
        avdName: @escaping @MainActor () async -> String?,
        replaceFocusedText: @escaping @MainActor (String) async throws -> TextReplacement,
        focusedSecureField: @escaping @MainActor () async -> FocusedSecureField = { .notSecure },
        secretHelper: @escaping @MainActor () async throws -> HelperInputDriver = {
            throw AndroidError.secretNeedsHelper("the device", reason: "no helper was offered")
        },
        requireForeground: @escaping @MainActor () async throws -> Void = {},
        multiTouchHelper: @escaping @MainActor () async throws -> HelperInputDriver? = { nil },
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
        self.secretHelper = secretHelper
        self.requireForeground = requireForeground
        self.multiTouchHelper = multiTouchHelper
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
        if !foregroundChecked, !Self.onlyButtons(event) {
            try await requireForeground()
            foregroundChecked = true
        }
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
        if case .adb = route.executor, steps.contains(where: \.isMultiTouch), let helper = try await multiTouchHelper() {
            route = AndroidInputRoute(executor: .helper(helper), scale: route.scale, clipboard: route.clipboard, adbReason: route.adbReason)
            resolvedRoute = route
        }
        try await run(steps, through: route.executor)
        touchIsDown = down
    }

    /// Buttons, such as Home or Back, only take a phone away from what is in front, so they skip the foreground check.
    static func onlyButtons(_ event: InputEvent) -> Bool {
        switch event {
        case .button, .shortButtonPress, .delay: return true
        case .composite(let events): return events.allSatisfy(onlyButtons)
        default: return false
        }
    }

    /// All-ASCII text as key events (gRPC `text` chunks, or adb `input text`); anything else pasted whole.
    func typeText(_ text: String) async throws {
        try await timing.measure(.input) {
            try await dispatchText(text)
        }
    }

    private func dispatchText(_ text: String) async throws {
        try await requireForeground()
        foregroundChecked = true
        let route = try await route()
        let secret = InputSecrecy.isSecret
        switch try AndroidTextPlan.make(for: text) {
        case .paste(let whole):
            if try await appendThroughHelper(whole) { return }
            guard !secret else { throw AndroidError.secretPasteRefused(device.rawValue) }
            guard let clipboard = route.clipboard else {
                throw AndroidError.grpcRequiredForText(serial: device.rawValue, avd: await avdName(), reason: route.adbReason)
            }
            switch await focusedSecureField() {
            case .secure: throw AndroidError.securePasteRefused(device.rawValue)
            case .unknown: throw AndroidError.securePasteUnconfirmed(device.rawValue)
            case .notSecure: break
            }
            try await paste(whole, through: clipboard)
        case .keys(let chunks):
            if case .grpc(let driver) = route.executor {
                try await type(chunks, on: driver.emulator)
                return
            }
            if case .helper(let driver) = route.executor {
                try await driver.type(chunks)
                return
            }
            // A password never becomes an `input text` argument, which the device's process list shows.
            let typingSecret = secret ? true : await focusedSecureField() == .secure
            if typingSecret {
                try await secretHelper().type(chunks)
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

    /// Non-ASCII text through the running helper's `setText`, appended to the field's text, so it never reaches a clipboard.
    /// False without a running helper or when the field refuses it; a password field, whose text cannot be read, is refused.
    private func appendThroughHelper(_ text: String) async throws -> Bool {
        guard let reading = await readFocusedField() else { return false }
        guard !reading.secure, let current = reading.text else { throw AndroidError.securePasteRefused(device.rawValue) }
        switch try await replaceFocusedText(current + text) {
        case .replaced:
            return true
        case .replacedWrongLength(let field):
            try await confirmReplacement(current + text, field: field)
            return true
        case .useKeys:
            return false
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
        if !InputSecrecy.isSecret, let clipboard = try await route().clipboard {
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

    private func run(_ steps: [AndroidInputStep], through executor: AndroidInputExecutor) async throws {
        if let last = steps.last(where: { if case .touch = $0 { return true } else { return false } }), case .touch(_, let point) = last {
            lastTouch = point
        }
        let pressesDown = steps.contains { if case .touch(.down, _) = $0 { return true } else { return false } }
        var scripts: [String] = []
        if case .adb = executor {
            scripts = try AdbInputScript.scripts(for: steps)
        }
        let fingersBefore = heldFingers
        for step in steps {
            if case .touches(let phase, let points) = step {
                heldFingers = phase == .up ? [] : points
            }
        }
        do {
            switch executor {
            case .adb(let shell):
                let wait = AdbInputScript.waitTime(of: steps)
                for script in scripts {
                    try await shell.run(script, waiting: wait)
                }
            case .grpc(let driver):
                try await driver.run(steps)
            case .helper(let driver):
                try await driver.run(steps)
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

extension AndroidInputStep {
    var isMultiTouch: Bool {
        if case .touches = self { return true }
        return false
    }

    var fingersDown: [AndroidPoint]? {
        if case .touches(.down, let points) = self { return points }
        return nil
    }
}
