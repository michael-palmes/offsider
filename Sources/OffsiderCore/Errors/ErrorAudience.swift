import Darwin

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

    /// A person when stderr is a terminal and the command does not report in JSON.
    public static var current: ErrorAudience {
        detects && !jsonOutput && isatty(STDERR_FILENO) != 0 ? .person : .agent
    }

    /// The step only a person may take: an agent is asked to fetch the user; a person reads the command on the `Try:` line, so gets nothing here.
    public func personStep(_ command: String, agentTail: String = "") -> String {
        self == .agent ? " Ask the user to run `\(command)` in their own terminal\(agentTail)." : ""
    }
}
