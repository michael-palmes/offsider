import ArgumentParser
import Foundation
import OffsiderCore

struct Type: AsyncParsableCommand, VerifiableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Type text by entering a sequence of characters.",
        discussion: """
        Input Methods:
        1. Direct text: offsider type "Hello World" --device DEVICE_ID
        2. From stdin: echo "Hello World!" | offsider type --stdin --device DEVICE_ID
        3. From file: offsider type --file text.txt --device DEVICE_ID

        Replacing a field's text:
        • offsider type --replace "new text" --device DEVICE_ID sets the focused field to exactly "new text"
        • offsider type --replace "" --device DEVICE_ID clears it
        
        Examples:
        • Simple text: offsider type "Hello World" --device DEVICE_ID
        • With spaces: offsider type "Hello, how are you?" --device DEVICE_ID
        • Special characters: offsider type 'Hello!' --device DEVICE_ID
        
        Shell Escaping Tips:
        • Use double quotes for text with spaces: "Hello World"
        • Use single quotes for text with special characters: 'Hello!'
        • For complex text or automation, prefer --stdin or --file methods
        
        Character Support:
        • Only US keyboard characters are supported via HID keycodes
        • Supported: A-Z, a-z, 0-9, and symbols: !@#$%^&*()_+-={}[]|\\:";'<>?,./`~
        • Not supported: International characters (£€¥), accented letters (éñü), etc.
        • This is a limitation of the underlying HID keyboard protocol
        
        Note: iOS may apply smart punctuation spacing to some characters.

        Android emulators: printable ASCII, newlines and tabs are typed as key events. Text with any other
        character needs the emulator's gRPC endpoint. --replace sets the text in one accessibility action
        (any Unicode, no gRPC needed); a trailing newline is then pressed as Return.
        """
    )
    
    @Argument(help: "The text to type. Use quotes for text with spaces or special characters.")
    var text: String?
    
    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    var useStdin: Bool = false
    
    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    var inputFile: String?

    @Flag(name: .customLong("replace"), help: "Replace the focused field's text instead of adding to it (an empty TEXT clears it).")
    var replace = false
    
    @OptionGroup
    var verification: VerificationOptions

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        let sourceCount = [text != nil, useStdin, inputFile != nil].filter { $0 }.count
        if sourceCount > 1 {
            throw ValidationError("Please specify only one input source: text argument, --stdin, or --file.")
        }

        if sourceCount == 0 {
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        }
    }

    func run() async throws {
        guard verification.verify else {
            try await execute(progress: nil)
            return
        }
        try await VerifyOutput.reportingFailures(command: "type", target: "text", options: verification) { progress in
            try await execute(progress: progress)
        }
    }

    private func execute(progress: VerifyProgress?) async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        try await execute(on: route, progress: progress, logger: logger)
    }

    /// Logs the character count only, never the text: the unified log keeps what it is given.
    func execute(on route: DeviceRouter.Route, progress: VerifyProgress?, logger: OffsiderLogger) async throws {
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        let inputText = try resolvedText()
        logger.info().log("Typing \(inputText.count) character\(inputText.count == 1 ? "" : "s")")

        if device.platform == .android {
            try await typeOnAndroid(inputText, backend: backend, device: device, progress: progress)
            return
        }

        do {
            try TextToHIDEvents.checkSupported(inputText)
        } catch {
            logger.error().log(error.localizedDescription)
            throw error
        }

        // Convert text to HID events using the new utility
        let hidEvents: [InputEvent]
        do {
            hidEvents = try Self.iosEvents(for: inputText, replacing: replace)
            logger.info().log("Successfully converted text to \(hidEvents.count) HID events")
        } catch let error as TextToHIDEvents.TextConversionError {
            logger.error().log("Text conversion failed: \(error.localizedDescription)")
            throw error
        } catch {
            logger.error().log("Unexpected error during text conversion: \(error.localizedDescription)")
            throw error
        }
        
        logger.info().log("Performing HID event sequence for text typing")

        if let progress {
            let target = "text (\(inputText.count) character\(inputText.count == 1 ? "" : "s"))"
            let request = VerifyRequest(
                command: "type",
                subject: "Typing \(target)",
                target: target,
                backend: backend,
                device: device,
                options: verification,
                styles: Array(repeating: nil, count: RetryPolicy.attemptCount(retries: verification.resolvedRetries))
            )
            try await VerifyOutput.perform(request, progress: progress) { _, session in
                try await session.perform(.composite(hidEvents))
            }
            return
        }

        if !hidEvents.isEmpty {
            // Keep typing in one ordered session. Indigo awaits each send, while DTUHID adds its
            // own keyboard pacing; unconditional delays here would double-pace the DTUHID path.
            try await backend.performTracked(InputEvent.composite(hidEvents), on: device)
        }
        
        logger.info().log("Text typing completed successfully")
    }
    
    /// Android picks key events or a paste itself, so the US-keyboard check and HID conversion do not apply.
    private func typeOnAndroid(_ inputText: String, backend: any DeviceBackend, device: DeviceID, progress: VerifyProgress?) async throws {
        let typeText: @MainActor (any InputSession) async throws -> Void = { session in
            guard let textSession = session as? any TextInputSession else {
                throw CLIError(errorDescription: "This device's input session cannot type text.", reason: .internalError)
            }
            if replace {
                try await textSession.replaceText(inputText)
            } else {
                try await textSession.typeText(inputText)
            }
        }
        guard let progress else {
            let session = try await backend.openTrackedSession(for: device)
            do {
                try await typeText(session)
            } catch {
                await session.close()
                throw error
            }
            await session.close()
            return
        }
        let target = "text (\(inputText.count) character\(inputText.count == 1 ? "" : "s"))"
        let request = VerifyRequest(
            command: "type",
            subject: "Typing \(target)",
            target: target,
            backend: backend,
            device: device,
            options: verification,
            styles: Array(repeating: nil, count: RetryPolicy.attemptCount(retries: verification.resolvedRetries))
        )
        try await VerifyOutput.perform(request, progress: progress) { _, session in
            try await typeText(session)
        }
    }

    /// iOS key events: with `replacing`, Command-A and Backspace first, in the same composite as the typing.
    static func iosEvents(for text: String, replacing: Bool) throws -> [InputEvent] {
        let typed = try TextToHIDEvents.convertTextToHIDEvents(text)
        return replacing ? [InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey)] + typed : typed
    }

    // MARK: - Input Methods

    /// The argument, stdin or file text, in Unicode NFC, so a decomposed `e` plus U+0301 types as one `é`.
    func resolvedText(readStandardInput: (() -> String)? = nil) throws -> String {
        let source: String
        switch (text, useStdin, inputFile) {
        case (let positionalText?, false, nil):
            source = positionalText
        case (nil, true, nil):
            source = (readStandardInput ?? readFromStdin)()
        case (nil, false, let file?):
            source = try readFromFile(file)
        case (nil, false, nil):
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        default:
            throw ValidationError("Please specify only one input source: text argument, --stdin, or --file.")
        }
        return source.precomposedStringWithCanonicalMapping
    }

    func readFromStdin() -> String {
        var input = ""
        while let line = readLine() {
            if !input.isEmpty {
                input += "\n"
            }
            input += line
        }
        return input
    }
    
    func readFromFile(_ filePath: String) throws -> String {
        do {
            return try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            throw ValidationError("Failed to read file '\(filePath)': \(error.localizedDescription)")
        }
    }
}
