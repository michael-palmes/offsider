import ArgumentParser
import Foundation
import OffsiderCore

enum BatchStepKind: String {
    case tap
    case swipe
    case gesture
    case touch
    case type
    case button
    case key
    case keySequence = "key-sequence"
    case keyCombo = "key-combo"
    /// `rn devmenu <item>`, the only `rn` step.
    case rn
    case sleep
    case wait
    case assert
    case screenshot
    case describeUI = "describe-ui"

    /// True when the step sends input or sleeps, so the screen may have changed after it.
    var mayChangeScreen: Bool {
        switch self {
        case .tap, .swipe, .gesture, .touch, .type, .button, .key, .keySequence, .keyCombo, .rn, .sleep:
            return true
        case .wait, .assert, .screenshot, .describeUI:
            return false
        }
    }
}

/// A parsed step: input to send through the shared session, or a read that reports a result.
enum BatchStep {
    case input([BatchPrimitive])
    case read(any BatchReadable)
}

@MainActor
struct BatchStepParser {
    nonisolated static let unsupportedFlags = ["--verify", "--verify-timeout", "--retries"]
    nonisolated static let unsupportedFlagsMessage = "Batch steps do not support --verify. Run the command on its own with --verify, or check with describe-ui after the batch."
    nonisolated static let stepJSONMessage = "Batch steps do not take --json. Use batch --json for one JSON line per step."
    nonisolated static let rnStepMessage = "The only rn batch step is rn devmenu with an item or --label, such as rn devmenu reload; listing the menu leaves it open, so run that on its own."

    nonisolated static func rejectUnsupportedFlags(_ tokens: [String]) throws {
        let arguments = tokens.dropFirst()
        func has(_ flag: String) -> Bool {
            arguments.contains { $0 == flag || $0.hasPrefix(flag + "=") }
        }
        if has("--json") {
            throw ValidationError(stepJSONMessage)
        }
        if unsupportedFlags.contains(where: has) {
            throw ValidationError(unsupportedFlagsMessage)
        }
    }

    /// Parses a step; input steps also resolve their targets now, reads run later through `BatchReadable`.
    static func parseStep(
        _ tokens: [String],
        deviceID: String,
        context: BatchContext,
        logger: OffsiderLogger
    ) async throws -> BatchStep {
        guard let firstToken = tokens.first else {
            return .input([])
        }

        guard let kind = BatchStepKind(rawValue: firstToken) else {
            throw ValidationError("Unsupported batch step '\(firstToken)'.")
        }

        if kind == .sleep {
            return .input(try parseSleep(tokens))
        }

        try rejectUnsupportedFlags(tokens)
        if kind == .rn {
            guard tokens.count > 1, tokens[1] == "devmenu" else { throw ValidationError(rnStepMessage) }
        }
        let stepArguments = Array(tokens.dropFirst(kind == .rn ? 2 : 1))
        try rejectPerStepDevice(stepArguments)
        if let hint = ArgumentHints.hint(for: tokens) {
            throw ValidationError(hint.message)
        }
        // Before the step's own arguments, so a `--` terminator cannot turn the device into text.
        let arguments = ["--device", deviceID] + stepArguments

        switch kind {
        case .tap:
            return .input(try await parseCommand(Tap.self, arguments: arguments, context: context, logger: logger))
        case .swipe:
            return .input(try await parseCommand(Swipe.self, arguments: arguments, context: context, logger: logger))
        case .gesture:
            return .input(try await parseCommand(Gesture.self, arguments: arguments, context: context, logger: logger))
        case .touch:
            return .input(try await parseCommand(Touch.self, arguments: arguments, context: context, logger: logger))
        case .type:
            return .input(try await parseCommand(Type.self, arguments: arguments, context: context, logger: logger))
        case .button:
            return .input(try await parseCommand(Button.self, arguments: arguments, context: context, logger: logger))
        case .key:
            return .input(try await parseCommand(Key.self, arguments: arguments, context: context, logger: logger))
        case .keySequence:
            return .input(try await parseCommand(KeySequence.self, arguments: arguments, context: context, logger: logger))
        case .keyCombo:
            return .input(try await parseCommand(KeyCombo.self, arguments: arguments, context: context, logger: logger))
        case .rn:
            return .input(try await parseCommand(RNDevMenu.self, arguments: arguments, context: context, logger: logger))
        case .wait:
            return .read(try parseRead(Wait.self, arguments: arguments, context: context))
        case .assert:
            return .read(try parseRead(Assert.self, arguments: arguments, context: context))
        case .screenshot:
            return .read(try parseRead(Screenshot.self, arguments: arguments, context: context))
        case .describeUI:
            return .read(try parseRead(DescribeUI.self, arguments: arguments, context: context))
        case .sleep:
            return .input([])
        }
    }

    private static func parseRead<C: AsyncParsableCommand & BatchReadable>(_ type: C.Type, arguments: [String], context: BatchContext) throws -> C {
        guard var parsed = try C.parseAsRoot(arguments) as? C else {
            throw CLIError(errorDescription: "Failed to parse batch step arguments: \(arguments.joined(separator: " "))", reason: .usage)
        }
        try parsed.validate()
        context.applyApp(of: parsed)
        return parsed
    }

    private static func parseCommand<C: AsyncParsableCommand & BatchConvertible>(
        _ type: C.Type,
        arguments: [String],
        context: BatchContext,
        logger: OffsiderLogger
    ) async throws -> [BatchPrimitive] {
        guard var parsed = try C.parseAsRoot(arguments) as? C else {
            throw CLIError(errorDescription: "Failed to parse batch step arguments: \(arguments.joined(separator: " "))", reason: .usage)
        }
        if (parsed as? VerifiableCommand)?.verification.isRequested == true {
            throw ValidationError(unsupportedFlagsMessage)
        }
        try parsed.validate()
        context.applyApp(of: parsed)
        return try await parsed.toBatchPrimitives(context: context, logger: logger)
    }

    nonisolated static let perStepDeviceMessage = "Batch steps cannot choose their own device. Use batch-level --device."

    nonisolated static func rejectPerStepDevice(_ args: [String]) throws {
        let flags = ["--device", "--udid"]
        if args.contains(where: { arg in flags.contains { arg == $0 || arg.hasPrefix($0 + "=") } }) {
            throw ValidationError(perStepDeviceMessage)
        }
        if args.contains(where: { $0 == "--wait-lock" || $0.hasPrefix("--wait-lock=") }) {
            throw ValidationError(perStepWaitLockMessage)
        }
    }

    nonisolated static let perStepWaitLockMessage = "Batch steps do not take --wait-lock. Pass it to batch, which locks the device once for every step."

    private static func parseSleep(_ tokens: [String]) throws -> [BatchPrimitive] {
        guard tokens.count == 2 else {
            throw ValidationError("Sleep step format: sleep <seconds>")
        }
        guard let seconds = Double(tokens[1]), seconds >= 0 else {
            throw ValidationError("Sleep step requires a non-negative number of seconds.")
        }
        return [.hostSleep(seconds)]
    }
}
