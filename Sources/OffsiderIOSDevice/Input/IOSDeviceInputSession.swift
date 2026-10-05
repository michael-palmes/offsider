import Foundation
import OffsiderCore

/// Text the HID keyboard cannot type: any Unicode, and replacing a field's text, through the device runner.
@MainActor
public protocol RunnerTextTyping: AnyObject {
    func typeText(_ text: String, on device: DeviceID) async throws
    func replaceText(_ text: String, on device: DeviceID) async throws
}

/// Input on an Xcode 27 host: everything through the device session broker when it sends touches and keys,
/// else touches through the runner; buttons fall back to the runner only for Home. Each lane connects on first use.
@MainActor
final class IOSDeviceInputSession: TextInputSession {
    let device: DeviceID
    private let session: () async throws -> DeviceSessionClient
    private let runner: (() async throws -> any InputSession)?
    private let runnerText: (any RunnerTextTyping)?
    private var lowering: DeviceSessionLowering?
    private var runnerSession: (any InputSession)?

    init(
        device: DeviceID, session: @escaping () async throws -> DeviceSessionClient,
        runner: (() async throws -> any InputSession)?, runnerText: (any RunnerTextTyping)?
    ) {
        self.device = device
        self.session = session
        self.runner = runner
        self.runnerText = runnerText
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
        guard try await touchLowering().brokerTouches else {
            try await requireRunner().performPhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay)
            return
        }
        if let preDelay, preDelay > 0 { try await Task.sleep(for: .seconds(preDelay)) }
        try await perform(.tapAt(x: point.x, y: point.y))
        if let postDelay, postDelay > 0 { try await Task.sleep(for: .seconds(postDelay)) }
    }

    /// US keyboard text through broker keys when it sends them; anything else through the runner.
    func typeText(_ text: String) async throws {
        if TextToHIDEvents.validateText(text), (try? await touchLowering())?.brokerTouches == true {
            let requests = try Self.keyRequests(typing: text)
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
            return
        }
        try await requireRunnerText("Typing text").typeText(text, on: device)
    }

    /// Characters per `keys` request, so a long text never outgrows the broker's request limit or its reply timeout.
    static let typingChunk = 256

    /// The whole text lowered before anything is sent, one request per `typingChunk` characters.
    static func keyRequests(typing text: String) throws -> [[DeviceSessionStep]] {
        var requests: [[DeviceSessionStep]] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: typingChunk, limitedBy: text.endIndex) ?? text.endIndex
            requests.append(try DeviceSessionLowering.keySteps(typing: String(text[start..<end])))
            start = end
        }
        return requests
    }

    func replaceText(_ text: String) async throws {
        try await requireRunnerText("Replacing a field's text").replaceText(text, on: device)
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
