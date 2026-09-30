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
    case grpc(GrpcInputDriver)
}

/// One command's input on one emulator; keeps finger state so a failed gesture can be lifted on close.
@MainActor
final class AndroidInputSession: InputSession, TextInputSession {
    let device: DeviceID
    private let executor: AndroidInputExecutor
    /// adb is always there, whatever carries the input.
    private let shell: AdbDeviceShell
    private let scale: Double
    /// The gRPC endpoint for the clipboard, even when a resized display keeps other input on adb.
    private let clipboard: (any EmulatorControlling)?
    /// Why there is no gRPC endpoint, for the error when text needs a paste.
    private let adbReason: AdbReason
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Looked up only when a message needs it, so ordinary input costs no extra adb call.
    private let avdName: @MainActor () async -> String?
    private let log: AndroidLog
    private var touchIsDown = false
    private var lastTouch: AndroidPoint?

    init(
        device: DeviceID,
        executor: AndroidInputExecutor,
        shell: AdbDeviceShell,
        geometry: AndroidDisplayGeometry,
        avdName: @escaping @MainActor () async -> String?,
        clipboard: (any EmulatorControlling)?,
        adbReason: AdbReason,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        log: @escaping AndroidLog
    ) {
        self.device = device
        self.executor = executor
        self.shell = shell
        self.scale = geometry.scale
        self.avdName = avdName
        self.clipboard = clipboard
        self.adbReason = adbReason
        self.sleep = sleep
        self.log = log
    }

    /// The emulator syncs its clipboard into the guest asynchronously, and the app reads it after the paste key.
    static let clipboardSyncWait = Duration.milliseconds(150)
    static let pasteReadWait = Duration.milliseconds(300)
    static let pasteKeyCode = 279

    func perform(_ event: InputEvent) async throws {
        var down = touchIsDown
        let steps = try AndroidInputLowering.steps(for: event, touchIsDown: &down, scale: scale)
        try await run(steps)
        touchIsDown = down
    }

    /// All-ASCII text as key events (gRPC `text` chunks, or adb `input text`); anything else pasted whole.
    func typeText(_ text: String) async throws {
        switch try AndroidTextPlan.make(for: text) {
        case .paste(let whole):
            guard let clipboard else {
                throw AndroidError.grpcRequiredForText(serial: device.rawValue, avd: await avdName(), reason: adbReason)
            }
            try await paste(whole, through: clipboard)
        case .keys(let chunks):
            if case .grpc(let driver) = executor {
                try await type(chunks, on: driver.emulator)
                return
            }
            let commands = try chunks.flatMap { chunk -> [String] in
                switch chunk {
                case .text(let run): return AdbShellQuoting.inputTextCommands(for: run)
                case .key(let usage): return ["input keyevent \(try AndroidKeyTable.requireKeyCode(for: usage))"]
                }
            }
            guard !commands.isEmpty else { return }
            try await shell.run(commands.joined(separator: " && "))
        }
    }

    private func type(_ chunks: [AndroidTextPlan.Chunk], on emulator: any EmulatorControlling) async throws {
        for chunk in chunks {
            switch chunk {
            case .text(let run):
                try await emulator.sendKey(.text(run))
            case .key(let usage):
                guard let code = AndroidKeyTable.usbCode(for: usage) else { throw AndroidError.unsupportedKey(usage) }
                try await emulator.sendKey(.usb(code, .press))
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
        guard touchIsDown, let point = lastTouch else { return }
        touchIsDown = false
        do {
            switch executor {
            case .adb(let shell):
                try await shell.run("input motionevent UP \(Int(point.x.rounded())) \(Int(point.y.rounded()))")
            case .grpc(let driver):
                try await driver.touch(point, down: false)
            }
        } catch {
            log(.warning, "Could not lift the touch left down on \(device.rawValue): \(error.localizedDescription)")
        }
    }

    private func run(_ steps: [AndroidInputStep]) async throws {
        if let last = steps.last(where: { if case .touch = $0 { return true } else { return false } }), case .touch(_, let point) = last {
            lastTouch = point
        }
        let pressesDown = steps.contains { if case .touch(.down, _) = $0 { return true } else { return false } }
        var scripts: [String] = []
        if case .adb = executor {
            scripts = try AdbInputScript.scripts(for: steps)
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
            }
        } catch {
            if pressesDown { touchIsDown = true }
            throw error
        }
    }
}
