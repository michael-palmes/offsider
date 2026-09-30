import Foundation
import OffsiderCore

/// Runs device shell scripts on one emulator; a non-zero `input` status is an error.
struct AdbDeviceShell: Sendable {
    let client: AdbClient
    let serial: String

    func run(_ script: String, waiting seconds: TimeInterval = 0) async throws {
        let timeout = Duration.seconds(15) + .milliseconds(Int((seconds * 1000).rounded(.up)))
        let label = script.count > 120 ? String(script.prefix(117)) + "..." : script
        let result = try await client.shell(script, on: serial, timeout: timeout, label: label)
        guard result.status == 0 else {
            let message = (result.stderrText + result.stdoutText).split(whereSeparator: \.isNewline).first.map(String.init)
            throw AndroidError.inputFailed(serial: serial, detail: message ?? "`input` exited \(result.status)")
        }
    }
}

enum AndroidInputExecutor: Sendable {
    case adb(AdbDeviceShell)
}

/// One command's input on one emulator; keeps finger state so a failed gesture can be lifted on close.
@MainActor
final class AndroidInputSession: InputSession, TextInputSession {
    let device: DeviceID
    private let executor: AndroidInputExecutor
    private let scale: Double
    /// Why a paste is impossible here, finishing "and <serial> ...".
    private let pasteUnavailableReason: String
    /// Looked up only when a message needs it, so ordinary input costs no extra adb call.
    private let avdName: @MainActor () async -> String?
    private let log: AndroidLog
    private var touchIsDown = false
    private var lastTouch: AndroidPoint?

    init(
        device: DeviceID,
        executor: AndroidInputExecutor,
        geometry: AndroidDisplayGeometry,
        avdName: @escaping @MainActor () async -> String?,
        pasteUnavailableReason: String,
        log: @escaping AndroidLog
    ) {
        self.device = device
        self.executor = executor
        self.scale = geometry.scale
        self.avdName = avdName
        self.pasteUnavailableReason = pasteUnavailableReason
        self.log = log
    }

    func perform(_ event: InputEvent) async throws {
        var down = touchIsDown
        let steps = try AndroidInputLowering.steps(for: event, touchIsDown: &down, scale: scale)
        try await run(steps)
        touchIsDown = down
    }

    func typeText(_ text: String) async throws {
        switch try AndroidTextPlan.make(for: text) {
        case .paste:
            throw AndroidError.grpcRequiredForText(serial: device.rawValue, avd: await avdName(), reason: pasteUnavailableReason)
        case .keys(let chunks):
            let commands = try chunks.flatMap { chunk -> [String] in
                switch chunk {
                case .text(let run): return AdbShellQuoting.inputTextCommands(for: run)
                case .key(let usage): return ["input keyevent \(try AndroidKeyTable.requireKeyCode(for: usage))"]
                }
            }
            guard case .adb(let shell) = executor, !commands.isEmpty else { return }
            try await shell.run(commands.joined(separator: " && "))
        }
    }

    func close() async {
        guard touchIsDown, let point = lastTouch, case .adb(let shell) = executor else { return }
        touchIsDown = false
        do {
            try await shell.run("input motionevent UP \(Int(point.x.rounded())) \(Int(point.y.rounded()))")
        } catch {
            log(.warning, "Could not lift the touch left down on \(device.rawValue): \(error.localizedDescription)")
        }
    }

    private func run(_ steps: [AndroidInputStep]) async throws {
        let scripts = try AdbInputScript.scripts(for: steps)
        if let last = steps.last(where: { if case .touch = $0 { return true } else { return false } }), case .touch(_, let point) = last {
            lastTouch = point
        }
        let pressesDown = steps.contains { if case .touch(.down, _) = $0 { return true } else { return false } }
        guard case .adb(let shell) = executor else { return }
        let wait = AdbInputScript.waitTime(of: steps)
        do {
            for script in scripts {
                try await shell.run(script, waiting: wait)
            }
        } catch {
            if pressesDown { touchIsDown = true }
            throw error
        }
    }
}
