import Foundation
import OffsiderCore

/// Writes a refusal only a person can clear into the caller's evidence run, so the morning's steps sit beside the captures.
/// Bound per command in `main.swift`; the default records nothing, so in-process tests never touch a developer's run.
@MainActor
final class PersonStepQueue {
    @TaskLocal static var current = PersonStepQueue(environment: nil, command: "", arguments: [])

    let environment: EvidenceRunEnvironment?
    let command: String
    let arguments: [String]
    private let start: Date

    nonisolated init(environment: EvidenceRunEnvironment?, command: String, arguments: [String]) {
        self.environment = environment
        self.command = command
        self.arguments = arguments
        start = environment?.now() ?? Date()
    }

    /// One manifest line with the failure's `ask`, when a run is active. Its arguments are redacted as a capture's are, and the ask too.
    func record(ask: String, exit: Int32, reason: String?, device: DeviceID?) {
        guard let environment, let run = try? RunRegistry.active(in: environment) else { return }
        let now = environment.now()
        let line = RunManifestLine(
            command: command, device: device?.rawValue, platform: device?.platform.rawValue, time: start, ms: Int((now.timeIntervalSince(start) * 1000).rounded()),
            exit: Int(exit), reason: reason, args: SelectorRedaction.redacted(arguments).map { LogRedactor.redact($0).text }, ask: LogRedactor.redact(ask).text
        )
        do {
            try run.folder.append(line)
        } catch {
            let message = TerminalText.line(OffsiderCommand.message(for: error), cap: TerminalText.maxErrorCharacters)
            Console.current.line(
                "Warning: could not add this step to \(run.folder.file(RunFolder.manifestName)): \(message)",
                person: .warning("This step is missing from the run's manifest: \(message)")
            )
        }
    }
}
