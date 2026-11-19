import Foundation
import OffsiderCore

/// Text the HID keyboard cannot type: any Unicode, and replacing a field's text, through the device runner.
@MainActor
public protocol RunnerTextTyping: AnyObject {
    func typeText(_ text: String, on device: DeviceID) async throws
    func replaceText(_ text: String, on device: DeviceID) async throws
}

/// Xcode 27 input: the broker when it sends touches and keys, else the runner for touches and Home; each lane connects on first use.
@MainActor
final class IOSDeviceInputSession: TextInputSession {
    let device: DeviceID
    private let session: () async throws -> DeviceSessionClient
    private let runner: (() async throws -> any InputSession)?
    private let runnerText: (any RunnerTextTyping)?
    private var lowering: DeviceSessionLowering?
    private var runnerSession: (any InputSession)?
    /// Runs before each batch: the device is still on USB and the pinned app is in front.
    private let preflight: () async throws -> Void

    init(
        device: DeviceID, session: @escaping () async throws -> DeviceSessionClient,
        runner: (() async throws -> any InputSession)?, runnerText: (any RunnerTextTyping)?,
        preflight: @escaping () async throws -> Void = {}
    ) {
        self.device = device
        self.session = session
        self.runner = runner
        self.runnerText = runnerText
        self.preflight = preflight
    }

    /// The broker when it answers and sends touches; the runner when it cannot and a runner exists; else the broker's failure.
    private func touchLowering() async throws -> DeviceSessionLowering {
        if let lowering { return lowering }
        let brokerTouches: Bool
        do {
            brokerTouches = try await session().supportsTouch || runner == nil
        } catch {
            guard runner != nil else { throw error }
            brokerTouches = false
        }
        let made = DeviceSessionLowering(brokerTouches: brokerTouches)
        lowering = made
        return made
    }

    /// Lowers the whole event before sending, so an unsupported part sends nothing.
    func perform(_ event: InputEvent) async throws {
        try await preflight()
        try await performChecked(event)
    }

    private func performChecked(_ event: InputEvent) async throws {
        var next = try await touchLowering()
        let actions = try next.actions(for: event)
        if !next.brokerTouches, actions.contains(where: { if case .keys = $0 { return true } else { return false } }) {
            throw IOSDeviceError.notSupportedOnDevice(
                "Pressing keys without the device session",
                instead: "Retry once `offsider doctor --device \(device.rawValue)` passes, or type text with `offsider type`."
            )
        }
        lowering = next
        for action in actions {
            try await run(action)
        }
    }

    private func run(_ action: DeviceSessionAction) async throws {
        switch action {
        case .touch(let steps):
            try await session().touch(steps)
        case .keys(let steps):
            try await session().keys(steps)
        case let .press(button, hold):
            let usage = try button.requireDeviceUsage()
            let runnerEvent: InputEvent = hold == button.deviceShortPressHold
                ? .shortButtonPress(button)
                : .composite([.button(direction: .down, button: button), .delay(hold), .button(direction: .up, button: button)])
            try await withRunnerFallback(button, runnerEvent) {
                try await $0.press(usagePage: DTUHIDMessage.consumerUsagePage, usageCode: usage, hold: hold)
            }
        case .runner(let event):
            try await requireRunner().perform(event)
        case .wait(let seconds):
            try await Task.sleep(for: .seconds(seconds))
        }
    }

    /// The broker first; when it cannot start, the runner presses Home; any other button reports the broker's failure.
    private func withRunnerFallback(_ button: HardwareButton, _ event: InputEvent, _ body: (DeviceSessionClient) async throws -> Void) async throws {
        let client: DeviceSessionClient
        do {
            client = try await session()
        } catch {
            guard button == .home, runner != nil else { throw error }
            try await requireRunner().perform(event)
            return
        }
        try await body(client)
    }

    func performPhysicalTap(at point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?) async throws {
        try await preflight()
        guard try await touchLowering().brokerTouches else {
            try await requireRunner().performPhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay)
            return
        }
        if let preDelay, preDelay > 0 { try await Task.sleep(for: .seconds(preDelay)) }
        try await performChecked(.tapAt(x: point.x, y: point.y))
        if let postDelay, postDelay > 0 { try await Task.sleep(for: .seconds(postDelay)) }
    }

    /// US keyboard text through broker keys when it sends them; anything else through the runner.
    func typeText(_ text: String) async throws {
        try await preflight()
        let keys = await typesWithKeys(text)
        if InputSecrecy.keysOnly, !keys { throw IOSDeviceError.keysOnlyRefusal(text, device: device) }
        guard keys else { return try await requireRunnerText("Typing text").typeText(text, on: device) }
        try await send(try Self.keyRequests(typing: text), typing: text)
    }

    /// True when `text` goes as broker keys: US keyboard text, with a broker that sends them.
    func typesWithKeys(_ text: String) async -> Bool {
        guard TextToHIDEvents.validateText(text) else { return false }
        return (try? await touchLowering())?.brokerTouches == true
    }

    private func send(_ requests: [[DeviceSessionStep]], typing text: String) async throws {
        for (index, steps) in requests.enumerated() {
            do {
                try await session().keys(steps)
            } catch let error as IOSDeviceError where index > 0 {
                throw IOSDeviceError(
                    .sessionLost,
                    "Offsider typed the first \(index * Self.typingChunk) of \(text.count) characters on \(device.rawValue), then: \(error.message) Check the field before typing the rest."
                )
            }
        }
    }

    /// Characters per `keys` request, so a long text never outgrows the broker's request limit, its pause budget or its reply timeout.
    static let typingChunk = 256

    /// The pause between characters. The broker hands keys over faster than an app that handles each on its JavaScript thread takes them, as React Native does, and such an app then drops some; a device cannot say which apps those are, so every app's keys are paced.
    static let keyGap: TimeInterval = 0.03

    /// The whole text lowered before anything is sent, one request per `typingChunk` characters, `gap` seconds between characters; `prefix` goes at the head of the first request.
    static func keyRequests(typing text: String, gap: TimeInterval = keyGap, after prefix: [DeviceSessionStep] = []) throws -> [[DeviceSessionStep]] {
        var requests: [[DeviceSessionStep]] = []
        var steps = prefix
        for (index, character) in text.enumerated() {
            if index > 0, index % typingChunk == 0 {
                requests.append(steps)
                steps = []
            }
            if index > 0, gap > 0 { steps.append(.wait(gap)) }
            steps += try DeviceSessionLowering.keySteps(typing: String(character))
        }
        if !steps.isEmpty { requests.append(steps) }
        return requests
    }

    /// US keyboard text as Command-A, Delete and paced keys through the broker, so no key waits on XCTest; anything else through the runner. Only `login` replaces a password field's text.
    func replaceText(_ text: String) async throws {
        try await preflight()
        let keys = await typesWithKeys(text)
        if InputSecrecy.keysOnly, !keys { throw IOSDeviceError.keysOnlyRefusal(text, device: device) }
        if !InputSecrecy.keysOnly, InputSecrecy.knownFocus == .secure {
            throw IOSDeviceError.secureFieldRunnerRefusal(text, replace: true, udid: device.rawValue)
        }
        guard keys else { return try await requireRunnerText("Replacing a field's text").replaceText(text, on: device) }
        try await send(try Self.keyRequests(typing: text, after: try Self.clearSteps(settling: !text.isEmpty)), typing: text)
    }

    /// Command-A, a pause, then Delete on the focused field, as a hardware keyboard would send them; `settling` adds the pause a field needs before new text.
    static func clearSteps(settling: Bool) throws -> [DeviceSessionStep] {
        try DeviceSessionLowering.keySteps(for: InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey, settle: settling ? InputEvent.iosClearSettle : 0))
    }

    func close() async {
        await runnerSession?.close()
        runnerSession = nil
    }

    private func requireRunner() async throws -> any InputSession {
        if let runnerSession { return runnerSession }
        guard let runner else {
            throw IOSDeviceError.notSupportedOnDevice("Touch input", instead: "This installation of Offsider has no device runner; reinstall Offsider.")
        }
        let opened = try await runner()
        runnerSession = opened
        return opened
    }

    private func requireRunnerText(_ what: String) throws -> any RunnerTextTyping {
        guard let runnerText else {
            throw IOSDeviceError.notSupportedOnDevice(what, instead: "This installation of Offsider has no device runner; reinstall Offsider.")
        }
        return runnerText
    }
}
