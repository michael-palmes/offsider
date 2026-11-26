import Foundation
import OffsiderCore

/// Whether this process runs with nobody at the Mac (`OFFSIDER_UNATTENDED`), and the step a refusal leaves for the person.
enum Unattended {
    /// Tests bind the answer.
    @TaskLocal static var isOn: Bool = UnattendedMode.isOn(environment: ProcessInfo.processInfo.environment)
    /// The arguments after `offsider`; tests bind them.
    @TaskLocal static var arguments: @Sendable () -> [String] = { Array(CommandLine.arguments.dropFirst()) }

    /// This command as a person would type it, or nil when its arguments hold a selector a run manifest would hide.
    static func currentCommand() -> String? {
        let arguments = arguments()
        guard !arguments.isEmpty, SelectorRedaction.redacted(arguments) == arguments, arguments.allSatisfy({ LogRedactor.redact($0).text == $0 }) else { return nil }
        return (["offsider"] + arguments.map(VerifyOutput.shellWord)).joined(separator: " ")
    }

    /// `Can you run `offsider ...` at the Mac and <then>?`, or the step in plain words when the command cannot be shown.
    static func runAsk(then: String) -> String {
        guard let command = currentCommand() else { return "Can you run this Offsider step again at the Mac and \(then)?" }
        return "Can you run `\(command)` at the Mac and \(then)?"
    }
}
