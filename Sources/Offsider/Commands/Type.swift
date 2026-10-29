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
        3. From file: offsider type --file text.txt --device DEVICE_ID (a regular UTF-8 file of at most 64 KiB;
           files under ~/.ssh, ~/.aws, ~/.config and similar, and names such as .env or id_rsa, need --allow-path, which a person confirms at a terminal with Touch ID or the password)

        Password fields: text given as an argument is refused (exit 64, secure_field_argument) when the field it
        names with --into-id, --into-label or --into-label-contains, or the field with focus, is a password field;
        use `offsider login`, or --stdin. An iOS simulator does not report focus, so without a named field the
        argument is typed there.

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
          never does (exit 5, focus_not_confirmed), and nothing at all when the keyboard covers the field (exit 1,
          target_under_keyboard). --into-label works the same by label, and --into-label-contains by
          part of a label. When the keyboard is
          already up for another field, a simulator cannot prove focus: Offsider taps, types and prints a warning.
        • --require-focus-id email-field types only when that field already has focus (exit 2, focus_mismatch,
          otherwise); the iOS simulator's tree does not report focus, so use --into-id there.
        • On a physical iPhone or iPad, --app <bundle-id> names the app whose field these find and the text goes to.

        Android emulators: printable ASCII, newlines and tabs are typed as key events. Text with any other
        character needs the emulator's gRPC endpoint. --replace sets the text in one accessibility action
        (any Unicode, no gRPC needed); a trailing newline is then pressed as Return.
        """
    )
    
    @Argument(help: "The text to type. Use quotes for text with spaces or special characters.")
    var text: String?
    
    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    var useStdin: Bool = false
    
    @Option(name: .customLong("file"), help: "Read text from the specified file (UTF-8, at most 64 KiB).")
    var inputFile: String?

    @Flag(name: .customLong("allow-path"), help: "Let --file read a file in a folder or with a name that usually holds secrets, such as ~/.ssh or .env; a person confirms the path at a terminal with Touch ID or the password.")
    var allowPath = false

    @Flag(name: .customLong("replace"), help: "Replace the focused field's text instead of adding to it (an empty TEXT clears it).")
    var replace = false

    @Option(name: .customLong("into-id"), help: ArgumentHelp("Tap the field with this describe-ui id and wait until it has focus before typing; nothing is typed if it never does.", valueName: "id"))
    var intoID: String?

    @Option(name: .customLong("into-label"), help: ArgumentHelp("Like --into-id, for the field with this label.", valueName: "text"))
    var intoLabel: String?

    @Option(name: .customLong("into-label-contains"), help: ArgumentHelp("Like --into-id, for the field whose label holds this text, in the same case.", valueName: "text"))
    var intoLabelContains: String?

    @Option(name: .customLong("require-focus-id"), help: ArgumentHelp("Type only when the field with this id already has focus; exit 2 otherwise. Not on iOS simulators.", valueName: "id"))
    var requireFocusID: String?
    
    @OptionGroup
    var verification: VerificationOptions

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    func validate() throws {
        let sourceCount = [text != nil, useStdin, inputFile != nil].filter { $0 }.count
        if sourceCount > 1 {
            throw ValidationError("Please specify only one input source: text argument, --stdin, or --file.")
        }

        if sourceCount == 0 {
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        }
        if allowPath, inputFile == nil {
            throw ValidationError("--allow-path applies only to --file.")
        }
        let focusOptions = [intoID != nil, intoLabel != nil, intoLabelContains != nil, requireFocusID != nil].filter { $0 }.count
        if focusOptions > 1 {
            throw ValidationError("Use only one of --into-id, --into-label, --into-label-contains or --require-focus-id.")
        }
        for (name, value) in [("--into-id", intoID), ("--into-label", intoLabel), ("--into-label-contains", intoLabelContains), ("--require-focus-id", requireFocusID)] {
            if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("\(name) must not be empty.")
            }
        }
    }

    var intoQuery: AccessibilityQuery? {
        SelectorQuery.make(id: intoID, label: intoLabel, labelContains: intoLabelContains, value: nil)
    }

    static let focusTimeout: TimeInterval = 2
    static let focusPoll: Duration = .milliseconds(250)

    /// `--into-*` taps the field and waits for focus; `--require-focus-id` checks it. Either throws before any text is sent.
    /// Returns the password-field verdict of a read with no tap after it, for the input session to reuse; nil when there was none.
    @MainActor
    @discardableResult
    func ensureFocus(
        backend: any DeviceBackend,
        device: DeviceID,
        logger: OffsiderLogger,
        clock: PollClock = .live,
        warn: @MainActor (String) -> Void = { Console.current.notice(.warning(InputPersonView.sentence($0), agent: $0)) },
        beforeTap: @MainActor (UITree) throws -> Void = { _ in },
        refusingSecureTarget secureRefusal: CLIError? = nil,
        tap: @MainActor (InputEvent) async throws -> Void
    ) async throws -> KnownSecureFocus? {
        let simulator = device.platform == .ios && !device.isPhysicalIOSDevice
        guard requireFocusID != nil || intoQuery != nil else {
            // An unreadable screen does not block typing: Android still sends a password field's text through the helper.
            guard let secureRefusal, !simulator else { return nil }
            guard let tree = try? await backend.accessibilityTree(for: device) else { return .unknown }
            if tree.secureFocus == .secureFocused { throw secureRefusal }
            return .notSecure
        }
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
            if let secureRefusal, focused?.isSecure == true { throw secureRefusal }
            return nil
        }
        guard let query = intoQuery else { return nil }
        let cover = TapCover(override: "tap the field with `offsider tap --allow-covered` and type without --into-id")
        let polled = try await AccessibilityPoller.resolveWithPolling(
            query: query, on: backend, device: device, waitTimeout: 0, pollInterval: 0.25,
            settle: .guarded(record: await TreeCache.load(for: device, backend: backend)),
            coverCheck: { resolution, tree in
                try await Tap.withKeyboardAdvice({
                    try await cover.check(resolution, selector: query.selectorDescription, tree: tree, backend: backend, device: device)
                }, selector: query.selectorDescription, at: resolution.point, device: device, tree: tree)
            },
            logger: logger
        )
        let field = polled.value.matched ?? polled.value.target
        if let secureRefusal, field?.isSecure == true || polled.value.target?.isSecure == true { throw secureRefusal }
        let point = try await backend.deviceCoordinates(for: [polled.value.point], tree: polled.tree, on: device)[0]
        let keyboardAlreadyUp = simulator && polled.tree.roots.flatMap { $0.flattened() }.contains { $0.role == .keyboard }
        try beforeTap(polled.tree)
        try await tap(.tapAt(x: point.x, y: point.y))
        if keyboardAlreadyUp {
            try await clock.sleep(Self.focusPoll)
            warn("the keyboard was already up, so the iOS simulator cannot confirm which field has focus; check with assert --has-value.")
            logger.info().log("Tapped \(query.selectorDescription); focusCheck: unproven")
            return nil
        }
        let deadline = clock.now() + Self.focusTimeout
        repeat {
            try await clock.sleep(Self.focusPoll)
            if let tree = try? await backend.accessibilityTree(for: device), Self.hasFocus(field, query: query, in: tree, keyboardOnly: simulator) {
                logger.info().log("\(query.selectorDescription) has focus")
                return nil
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
        try await AllowPathConsent.confirm(path: inputFile, allowPath: allowPath, command: "type")
        guard verification.verify else {
            try await InputOutput.reporting(command: "type", target: "text", json: verification.json) { _ in
                try await execute(progress: nil)
                Console.current.show(InputPersonView.receipt(receiptHeadline))
            }
            return
        }
        try await VerifyOutput.reportingFailures(command: "type", target: "text", options: verification) { progress in
            try await execute(progress: progress)
        }
    }

    private func execute(progress: VerifyProgress?) async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let typing = { try await execute(on: route, progress: progress, logger: logger, refusingSecureArgument: text?.isEmpty == false) }
        // Standard input may be a person typing at the terminal, so no spinner draws over it.
        try await useStdin ? typing() : Console.current.progress("Typing", typing)
    }

    /// Where the text went, never the text or its length: `Typed into id=email`, `Cleared id=email`.
    var receiptHeadline: String {
        let field = intoID.map { "id=\($0)" } ?? intoLabel.map { "label=\($0)" } ?? intoLabelContains.map { "label-contains=\($0)" }
            ?? requireFocusID.map { "id=\($0)" }
        guard replace else { return field.map { "Typed into \($0)" } ?? "Typed into the focused field" }
        if text?.isEmpty == true { return "Cleared " + (field ?? "the focused field") }
        return "Replaced the text in " + (field ?? "the focused field")
    }

    /// Text typed as an argument stays in shell history and process lists, so it never goes into a password field.
    static func secureFieldRefusal(device: DeviceID, batch: Bool = false) -> CLIError {
        let login = "offsider login --device \(device.rawValue)"
        let why = batch
            ? "A batch type step is aimed at a password field, and the step's text stays in the batch file or command line"
            : "The field is a password field, and text given as an argument stays in shell history and process lists"
        let instead = batch ? "" : ", or pipe it in with `offsider type --stdin --device \(device.rawValue)`"
        return CLIError(
            errorDescription: "\(why), so Offsider typed nothing. Sign in with `\(login)`\(instead).",
            reason: .secureFieldArgument,
            hint: login
        )
    }

    /// Logs the character count only, never the text: the unified log keeps what it is given.
    /// `login` calls this directly with its secret already in place, so only `run` refuses an argument aimed at a password field.
    func execute(on route: DeviceRouter.Route, progress: VerifyProgress?, logger: OffsiderLogger, refusingSecureArgument: Bool = false) async throws {
        await appOption.apply(to: route)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        let inputText = try resolvedText()
        let throughSession = device.platform == .android || device.isPhysicalIOSDevice
        let hidEvents = throughSession ? [] : try Self.checkedIOSEvents(for: inputText, replacing: replace, logger: logger)
        let secureRefusal = refusingSecureArgument ? Self.secureFieldRefusal(device: device) : nil
        let knownFocus = try await ensureFocus(backend: backend, device: device, logger: logger, beforeTap: { tree in
            if progress != nil, case .appearing(let id) = verification.mode {
                try Verifier.refuseIfOnScreen(id, in: tree)
            }
        }, refusingSecureTarget: secureRefusal) { event in
            try await backend.performTracked(event, on: device)
        }
        logger.info().log("Typing \(inputText.count) character\(inputText.count == 1 ? "" : "s")")

        if throughSession {
            try await InputSecrecy.$fromArgument.withValue(refusingSecureArgument) {
                try await InputSecrecy.$knownFocus.withValue(knownFocus) {
                    try await typeThroughSession(inputText, backend: backend, device: device, progress: progress)
                }
            }
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
                styles: Array(repeating: nil, count: RetryPolicy.attemptCount(retries: verification.resolvedRetries)),
                personSubject: Self.personSubject
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
            styles: Array(repeating: nil, count: RetryPolicy.attemptCount(retries: verification.resolvedRetries)),
            personSubject: Self.personSubject
        )
        try await VerifyOutput.perform(request, progress: progress) { _, session in
            try await typeText(session)
        }
    }

    /// A person's verify lines name the input, never how long the text was.
    static let personSubject = "Typed text"

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
        return replacing ? [InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey, settle: InputEvent.iosClearSettle)] + typed : typed
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
    
    /// Through `TextFileInput`, which names the file it read on stderr; a person's note leaves out its size.
    func readFromFile(_ filePath: String) throws -> String {
        let read = try TextFileInput.read(filePath, allowing: allowPath ? AllowPathConsent.confirmed : nil)
        let shown = TerminalText.homePath(read.resolvedPath, home: FileManager.default.homeDirectoryForCurrentUser.path)
        Console.current.line(read.announcement, person: .note("Reading text from \(TerminalText.field(shown, profile: .person))", mark: .type))
        return read.text
    }
}

/// `--allow-path` reads a file where secrets live, so a person at a terminal confirms the resolved path with Touch ID or the password.
enum AllowPathConsent {
    /// The resolved path a person confirmed in this process.
    nonisolated(unsafe) static var confirmed: String?

    /// Asks only when `path` is one `--file` refuses; refuses with `person_required` without a terminal or a GUI session.
    static func confirm(path: String?, allowPath: Bool, command: String) async throws {
        guard allowPath, let path, let found = TextFileInput.sensitive(path) else { return }
        guard PersonPresence.terminal() else {
            throw CLIError.personRequired(
                "--allow-path needs a person at a terminal to confirm \(TerminalText.line(found.resolvedPath)). Nothing was read. Run it from your own terminal."
            )
        }
        try await PersonPresence.confirm(reason: "let \(command) read \(found.resolvedPath)")
        confirmed = found.resolvedPath
    }
}
