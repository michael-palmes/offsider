import Foundation

/// Why the helper could not serve this command; a fallback to uiautomator follows unless the helper was forced.
enum HelperUnavailableReason: Equatable, Sendable, CustomStringConvertible {
    case notBundled(String)
    case damaged(String)
    case pushFailed(String)
    case hiddenAPI(String)
    case connectFailed(String)
    case crashed(status: Int32, detail: String)
    case noReady(seconds: Int)
    case handshake(String)
    /// `OFFSIDER_ANDROID_TREE=uiautomator`
    case forcedOff

    init(_ error: HelperDexError) {
        switch error {
        case .notBundled(let detail): self = .notBundled(detail)
        case .damaged(let detail): self = .damaged(detail)
        case .protocolMismatch: self = .damaged(error.description)
        }
    }

    var description: String {
        switch self {
        case .notBundled: return "Offsider's resource bundle has no helper; reinstall Offsider"
        case .damaged: return "the helper in Offsider's resource bundle does not match its manifest; reinstall Offsider"
        case .pushFailed(let message): return "pushing it to /data/local/tmp failed: \(message)"
        case .hiddenAPI(let message): return "this Android version does not offer the hidden UiAutomation API it uses: \(message)"
        case .connectFailed(let message): return "it could not connect to UiAutomation: \(message)"
        case .crashed(let status, let detail): return "it exited with status \(status) before it was ready: \(detail)"
        case .noReady(let seconds): return "it did not start within \(seconds) s"
        case .handshake(let detail): return "its socket did not answer: \(detail)"
        case .forcedOff: return "OFFSIDER_ANDROID_TREE is uiautomator"
        }
    }
}

enum HelperStartFailure: Error, Equatable, Sendable {
    /// Another UiAutomation client holds the slot (exit 4); never a reason to fall back.
    case busy(detail: String)
    case unavailable(HelperUnavailableReason)
}

/// Starts the helper over one open shell stream, pushing the dex first when the device lacks this exact copy.
@MainActor
struct HelperLauncher {
    static let idleTimeoutMs = 10_000
    static let acceptTimeoutMs = 10_000
    /// Cold starts on a loaded host took up to 13 s, so the wait for the ready line is generous.
    static let readyTimeout: Duration = .seconds(30)
    static let pushTimeout: Duration = .seconds(10)
    static let missingStatus: Int32 = 90
    static let processName = "offsider-helper"
    static let mainClass = "com.mpalmes.offsider.helper.OffsiderHelper"
    static let startLabel = "offsider-helper serve"

    let client: AdbClient
    let serial: String
    let dex: HelperDex
    let log: AndroidLog
    var hostPid: Int32 = getpid()

    /// Exits 90 unless the dex has the right size; `exec` lets adbd's hang-up reach the helper; a push renames and prunes first.
    static func startScript(_ dex: HelperDex, pushedFrom temporaryPath: String?) -> String {
        var script = "f=\(AdbShellQuoting.quote(dex.devicePath)); "
        if let temporaryPath {
            script += "mv -f \(AdbShellQuoting.quote(temporaryPath)) \"$f\" && "
                + "for o in /data/local/tmp/offsider-helper-*.dex; do [ \"$o\" = \"$f\" ] || rm -f \"$o\"; done; "
        }
        return script
            + "[ \"$(stat -c %s \"$f\" 2>/dev/null)\" = \(dex.bytes.count) ] || exit \(missingStatus); "
            + "CLASSPATH=\"$f\" exec app_process /data/local/tmp --nice-name=\(processName) \(mainClass) serve "
            + "--idle-timeout-ms \(idleTimeoutMs) --accept-timeout-ms \(acceptTimeoutMs)"
    }

    var temporaryPath: String {
        "\(dex.devicePath).\(hostPid).tmp"
    }

    /// Starts the helper, pushing once on exit 90; throws `HelperStartFailure` or a device `AndroidError`.
    func launch() async throws -> (shell: ShellStream, ready: HelperReady) {
        let started = ContinuousClock.now
        if case .started(let shell, let ready) = try await attempt(Self.startScript(dex, pushedFrom: nil)) {
            log(.debug, "The UiAutomation helper on \(serial) was ready in \(Self.milliseconds(since: started)) ms (pid \(ready.pid))")
            return (shell, ready)
        }
        log(.debug, "\(dex.devicePath) is missing on \(serial); pushing it")
        do {
            try await client.push(dex.bytes, to: temporaryPath, mtime: UInt32(Date().timeIntervalSince1970), on: serial, timeout: Self.pushTimeout)
        } catch let error as AndroidError where error.kind == .adbCommandFailed {
            throw HelperStartFailure.unavailable(.pushFailed(Self.pushDetail(error)))
        }
        switch try await attempt(Self.startScript(dex, pushedFrom: temporaryPath)) {
        case .started(let shell, let ready):
            log(.debug, "The UiAutomation helper on \(serial) was pushed and ready in \(Self.milliseconds(since: started)) ms (pid \(ready.pid))")
            return (shell, ready)
        case .missing(let stderr):
            let line = Self.firstLine(stderr).map { ": \($0)" } ?? ""
            throw HelperStartFailure.unavailable(.pushFailed("the helper was still missing after the push\(line)"))
        }
    }

    private enum Attempt {
        case started(ShellStream, HelperReady)
        case missing(stderr: String)
    }

    private func attempt(_ script: String) async throws -> Attempt {
        let opened = try await client.openService("shell,v2,raw:" + script, on: serial, timeout: Self.readyTimeout)
        let shell = ShellStream(opened, serial: serial, label: Self.startLabel)
        let deadline = ContinuousClock.now + Self.readyTimeout
        var lines: [String] = []
        do {
            while true {
                switch try await shell.next(deadline: deadline) {
                case .line(let line):
                    guard line.hasPrefix("{"), let ready = try? HelperWire.ready(fromLine: line) else {
                        lines.append(line)
                        continue
                    }
                    guard ready.protocol == HelperDex.protocolVersion else {
                        throw HelperStartFailure.unavailable(.handshake(
                            "the helper on the device speaks protocol \(ready.protocol), Offsider speaks \(HelperDex.protocolVersion)"
                        ))
                    }
                    return .started(shell, ready)
                case .exited(let status, let stdout, let stderr):
                    await shell.close()
                    if status == Self.missingStatus {
                        return .missing(stderr: stderr)
                    }
                    throw Self.classify(status: status, stdout: (lines + [stdout]).joined(separator: "\n"), stderr: stderr)
                }
            }
        } catch let error as AdbConnectError {
            await shell.close()
            guard error == .timedOut else {
                throw await client.deviceError(error, serial: serial, command: Self.startLabel, timeout: Self.readyTimeout)
            }
            throw HelperStartFailure.unavailable(.noReady(seconds: Int(Self.readyTimeout.components.seconds)))
        } catch {
            await shell.close()
            throw error
        }
    }

    /// Exit statuses from the helper before its ready line; 90 is the start script's own.
    static func classify(status: Int32, stdout: String, stderr: String) -> HelperStartFailure {
        let reported = errorJSON(in: stdout)
        let message = reported.map { body in body.detail.map { "\(body.message) (\(Self.clipped($0)))" } ?? body.message }
            ?? firstLine(stderr) ?? firstLine(stdout) ?? "no output"
        switch status {
        case 2: return .unavailable(.handshake(message))
        case 3: return .unavailable(.hiddenAPI(message))
        case 4: return .busy(detail: reported?.detail ?? message)
        case 5: return .unavailable(.connectFailed(message))
        case missingStatus: return .unavailable(.pushFailed("the helper was still missing after the push"))
        default: return .unavailable(.crashed(status: status, detail: reported?.message ?? firstLine(stderr) ?? firstLine(stdout) ?? "no output"))
        }
    }

    private struct ErrorLine: Decodable {
        let error: HelperErrorBody
    }

    private static func errorJSON(in stdout: String) -> HelperErrorBody? {
        stdout.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("{") }
            .lazy
            .compactMap { try? JSONDecoder().decode(ErrorLine.self, from: Data($0.utf8)).error }
            .first
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func clipped(_ text: String) -> String {
        text.count > 200 ? String(text.prefix(200)) + "..." : text
    }

    private static func pushDetail(_ error: AndroidError) -> String {
        guard let range = error.message.range(of: ": ") else { return error.message }
        let detail = error.message[range.upperBound...]
        return String(detail.hasSuffix(".") ? detail.dropLast() : detail)
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
