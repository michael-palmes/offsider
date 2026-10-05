import Foundation
import OffsiderCore

/// Text the HID keyboard cannot type: any Unicode, and replacing a field's text, through the device runner.
@MainActor
public protocol RunnerTextTyping: AnyObject {
    func typeText(_ text: String, on device: DeviceID) async throws
    func replaceText(_ text: String, on device: DeviceID) async throws
}

/// Where a session's `dtuhidd` messages go; `CoreDeviceSession` on a device, a recorder in tests.
@MainActor
protocol DTUHIDSink: AnyObject {
    var hasSent: Bool { get }
    func send(_ message: DTUHIDValue, feature: String) async throws
    func close() async
}

extension CoreDeviceSession: DTUHIDSink {
    func send(_ message: DTUHIDValue, feature: String) async throws {
        try await link(feature).send(message)
    }
}

/// CoreDevice HID input for one command: touches, keys and buttons lowered to `dtuhidd` messages, each feature's socket opened on first use.
@MainActor
final class IOSDeviceInputSession: TextInputSession {
    let device: DeviceID
    private let sink: any DTUHIDSink
    private let runnerText: (any RunnerTextTyping)?
    private var lowering: DTUHIDLowering

    init(device: DeviceID, panel: IOSDevicePanel, sink: any DTUHIDSink, runnerText: (any RunnerTextTyping)?) {
        self.device = device
        self.sink = sink
        self.runnerText = runnerText
        lowering = DTUHIDLowering(panel: panel)
    }

    /// Lowers the whole event before sending, so an unsupported part sends nothing.
    func perform(_ event: InputEvent) async throws {
        var next = lowering
        let steps = try next.steps(for: event)
        lowering = next
        for step in steps {
            switch step {
            case let .send(message, feature):
                try await sink.send(message, feature: feature)
            case let .wait(seconds):
                try await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// US keyboard text goes through HID keys; anything else needs the runner.
    func typeText(_ text: String) async throws {
        guard TextToHIDEvents.validateText(text) else {
            try await requireRunner("Typing characters outside the US keyboard").typeText(text, on: device)
            return
        }
        try await perform(.composite(try TextToHIDEvents.convertTextToHIDEvents(text)))
    }

    func replaceText(_ text: String) async throws {
        try await requireRunner("Replacing a field's text").replaceText(text, on: device)
    }

    func close() async {
        await sink.close()
    }

    private func requireRunner(_ what: String) throws -> any RunnerTextTyping {
        guard let runnerText else {
            throw IOSDeviceError.notSupportedOnDevice(
                what,
                instead: "This version of Offsider types only US keyboard characters on an iPhone or iPad; type the text without `--replace`, or clear the field first with `offsider key`."
            )
        }
        return runnerText
    }
}
