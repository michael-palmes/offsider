import ArgumentParser

/// A command's space-joined path from the root (`rn prepare`, `tap`), as `CommandEffect.table` and error envelopes name it.
enum CommandPath {
    static func of(_ command: any ParsableCommand) -> String {
        of(type(of: command))
    }

    static func of(_ command: any ParsableCommand.Type) -> String {
        path(to: ObjectIdentifier(command), in: OffsiderCommand.configuration.subcommands)?.joined(separator: " ")
            ?? command._commandName
    }

    /// Every leaf command's path, in registration order.
    static func all(in commands: [any ParsableCommand.Type] = OffsiderCommand.configuration.subcommands) -> [String] {
        commands.flatMap { command -> [String] in
            let children = command.configuration.subcommands
            return children.isEmpty ? [of(command)] : all(in: children)
        }
    }

    private static func path(to target: ObjectIdentifier, in commands: [any ParsableCommand.Type]) -> [String]? {
        for command in commands {
            if ObjectIdentifier(command) == target { return [command._commandName] }
            if let rest = path(to: target, in: command.configuration.subcommands) {
                return [command._commandName] + rest
            }
        }
        return nil
    }
}
