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

        Typing into a named field:
        • offsider type --into-id email-field --replace "a@b.c" --device DEVICE_ID taps the field, waits up to 2 s
          until it has focus (on an iOS simulator, until the keyboard shows), then types; no text is sent when it
          never does (exit 5, focus_not_confirmed). --into-label works the same by label. When the keyboard is
          already up for another field, a simulator cannot prove focus: Offsider taps, types and prints a warning.
        • --require-focus-id email-field types only when that field already has focus (exit 2, focus_mismatch,
          otherwise); the iOS simulator's tree does not report focus, so use --into-id there.

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

    @Option(name: .customLong("into-id"), help: ArgumentHelp("Tap the field with this describe-ui id and wait until it has focus before typing; nothing is typed if it never does.", valueName: "id"))
    var intoID: String?

    @Option(name: .customLong("into-label"), help: ArgumentHelp("Like --into-id, for the field with this label.", valueName: "text"))
    var intoLabel: String?

    @Option(name: .customLong("require-focus-id"), help: ArgumentHelp("Type only when the field with this id already has focus; exit 2 otherwise. Not on iOS simulators.", valueName: "id"))
    var requireFocusID: String?
    
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
        let focusOptions = [intoID != nil, intoLabel != nil, requireFocusID != nil].filter { $0 }.count
        if focusOptions > 1 {
            throw ValidationError("Use only one of --into-id, --into-label or --require-focus-id.")
        }
        for (name, value) in [("--into-id", intoID), ("--into-label", intoLabel), ("--require-focus-id", requireFocusID)] {
            if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("\(name) must not be empty.")
            }
        }
    }

    var intoQuery: AccessibilityQuery? {
        SelectorQuery.make(id: intoID, label: intoLabel, value: nil)
    }

    static let focusTimeout: TimeInterval = 2
    static let focusPoll: Duration = .milliseconds(250)

    /// `--into-*` taps the field and waits for focus; `--require-focus-id` checks it. Either throws before any text is sent.
    @MainActor
    func ensureFocus(
        backend: any DeviceBackend,
        device: DeviceID,
        logger: OffsiderLogger,
        clock: PollClock = .live,
        warn: @MainActor (String) -> Void = { FileHandle.standardError.write(Data("Warning: \($0)\n".utf8)) },
        beforeTap: @MainActor (UITree) throws -> Void = { _ in },
        tap: @MainActor (InputEvent) async throws -> Void
    ) async throws {
        let simulator = device.platform == .ios && !device.isPhysicalIOSDevice
        if let requireFocusID {
            guard !simulator else {
                throw CLIError(
                    errorDescription: "--require-focus-id needs the field's focus state, which an iOS simulator's tree does not report. Use --into-id \(requireFocusID) to tap the field and wait for the keyboard.",
                    reason: .notSupported
                )
            }
            let tree = try await backend.accessibilityTree(for: device)
            let focused = Self.focusedField(in: tree)
            guard focused?.normalizedID == requireFocusID else {
                let viewport = tree.viewport
                throw CLIError(
                    errorDescription: focused.map { "--require-focus-id '\(requireFocusID)' does not have focus; \(MatchSummary($0, viewport: viewport).text) does. No text was typed." }
                        ?? "--require-focus-id '\(requireFocusID)' does not have focus, and no field does. No text was typed.",
                    reason: .focusMismatch,
                    hint: "offsider type --into-id \(requireFocusID) --device \(device.rawValue)",
                    candidates: focused.map { [MatchSummary($0, viewport: viewport).failureCandidate] } ?? []
                )
            }
            return
        }
        guard let query = intoQuery else { return }
        let polled = try await AccessibilityPoller.resolveWithPolling(
            query: query, on: backend, device: device, waitTimeout: 0, pollInterval: 0.25, logger: logger
        )
        let field = polled.value.matched ?? polled.value.target
        let point = try await backend.deviceCoordinates(for: [polled.value.point], tree: polled.tree, on: device)[0]
        let keyboardAlreadyUp = simulator && polled.tree.roots.flatMap { $0.flattened() }.contains { $0.role == .keyboard }
        try beforeTap(polled.tree)
        try await tap(.tapAt(x: point.x, y: point.y))
        if keyboardAlreadyUp {
            try await clock.sleep(Self.focusPoll)
            warn("the keyboard was already up, so the iOS simulator cannot confirm which field has focus; check with assert --has-value.")
            logger.info().log("Tapped \(query.selectorDescription); focusCheck: unproven")
            return
        }
        let deadline = clock.now() + Self.focusTimeout
        repeat {
            try await clock.sleep(Self.focusPoll)
            if let tree = try? await backend.accessibilityTree(for: device), Self.hasFocus(field, query: query, in: tree, keyboardOnly: simulator) {
                logger.info().log("\(query.selectorDescription) has focus")
                return
            }
        } while clock.now() < deadline
        throw CLIError(
            errorDescription: "Tapped \(query.selectorDescription), but it did not take focus within \(Int(Self.focusTimeout)) s\(simulator ? " (no keyboard appeared)" : ""). No text was typed.",
            reason: .focusNotConfirmed,
            hint: "offsider describe-ui --summary --device \(device.rawValue)"
        )
    }

    /// The focused editable field, else any focused element.
    static func focusedField(in tree: UITree) -> UINode? {
        let focused = tree.roots.flatMap { $0.flattened() }.filter { $0.state.focused == true }
        return focused.first { $0.role.isTextInput } ?? focused.first
    }

    /// The field, or a focused field inside its frame, has focus; on an iOS simulator a keyboard shows while the field is still on screen.
    static func hasFocus(_ field: UINode?, query: AccessibilityQuery, in tree: UITree, keyboardOnly: Bool) -> Bool {
        let nodes = tree.roots.flatMap { $0.flattened() }
        if keyboardOnly {
            let keyboard = nodes.contains { $0.role == .keyboard }
            let stillThere = !AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: nil).onScreen.isEmpty
            return keyboard && stillThere
        }
        return nodes.contains { node in
            guard node.state.focused == true else { return false }
            if let id = field?.normalizedID { return node.normalizedID == id }
            guard let frame = field?.frame, let focusedFrame = node.frame else { return query.field(of: node) != nil }
            return frame.intersection(focusedFrame) != nil
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
        let throughSession = device.platform == .android || device.isPhysicalIOSDevice
        let hidEvents = throughSession ? [] : try Self.checkedIOSEvents(for: inputText, replacing: replace, logger: logger)
        try await ensureFocus(backend: backend, device: device, logger: logger, beforeTap: { tree in
            if progress != nil, case .appearing(let id) = verification.mode {
                try Verifier.refuseIfOnScreen(id, in: tree)
            }
        }) { event in
            try await backend.performTracked(event, on: device)
        }
        logger.info().log("Typing \(inputText.count) character\(inputText.count == 1 ? "" : "s")")

        if throughSession {
            try await typeThroughSession(inputText, backend: backend, device: device, progress: progress)
            return
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
    
    /// Android and physical iOS devices pick key events, a paste or the runner themselves, so the US-keyboard check and HID conversion do not apply here.
    private func typeThroughSession(_ inputText: String, backend: any DeviceBackend, device: DeviceID, progress: VerifyProgress?) async throws {
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

    /// The simulator's key events, checked before any focus tap so text the HID keyboard cannot type sends nothing.
    static func checkedIOSEvents(for text: String, replacing: Bool, logger: OffsiderLogger) throws -> [InputEvent] {
        do {
            try TextToHIDEvents.checkSupported(text)
            let events = try iosEvents(for: text, replacing: replacing)
            logger.info().log("Converted text to \(events.count) HID events")
            return events
        } catch {
            logger.error().log("Text conversion failed: \(error.localizedDescription)")
            throw error
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
