import Darwin
import Foundation

/// Who reads a failure: a person at a terminal, or an agent or script, which reads stderr or the JSON envelope.
public enum ErrorAudience: Equatable, Sendable {
    case person
    case agent

    /// Set once by the command line before a command runs; until then, as in tests, every reader is an agent.
    nonisolated(unsafe) private static var detects = false
    nonisolated(unsafe) private static var jsonOutput = false

    public static func configure(jsonOutput: Bool) {
        detects = true
        self.jsonOutput = jsonOutput
    }

    /// A person when stderr is a terminal, the command does not report in JSON and nothing marks the run as an agent's.
    public static var current: ErrorAudience {
        resolve(configured: detects, json: jsonOutput, stderrIsTerminal: isatty(STDERR_FILENO) != 0, environment: ProcessInfo.processInfo.environment)
    }

    public static func resolve(configured: Bool, json: Bool, stderrIsTerminal: Bool, environment: [String: String]) -> ErrorAudience {
        configured && !json && stderrIsTerminal && OutputProfile.resolve(environment: environment, isTerminal: true) == .person ? .person : .agent
    }

    /// The step only a person may take: an agent is asked to fetch the user; a person reads the command on the `Try:` line, so gets nothing here.
    public func personStep(_ command: String, agentTail: String = "") -> String {
        self == .agent ? " Ask the user to run `\(command)` in their own terminal\(agentTail)." : ""
    }
}
