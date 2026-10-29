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

        Focus: with no named field, text is typed only when a text field has focus (or a keyboard shows); otherwise
        nothing is sent (exit 1, no_focused_field), since keys that reach no field can act as app shortcuts, and a
        React Native dev build reloads on r. Tap the field first, or name it with --into-id.

        Password fields: text given as an argument is refused (exit 64, secure_field_argument) when the field it
        names with --into-id, --into-label or --into-label-contains, or the field with focus, is a password field;
        use `offsider login`, or --stdin.

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
        
        Note: iOS may apply smart punctuation spacing to some characters. On an iOS simulator, keys into a React Native
        app go 30 ms apart, so a field that sets its text from each change keeps up.

        Typing into a named field:
        • offsider type --into-id email-field --replace "a@b.c" --device DEVICE_ID taps the field, waits up to 2 s
          until it has focus, then types; no text is sent when it never does (exit 5, focus_not_confirmed), and
          nothing at all when the keyboard covers the field (exit 1, target_under_keyboard). --into-label works the
          same by label, and --into-label-contains by part of a label.
        • --require-focus-id email-field types only when that field already has focus (exit 2, focus_mismatch,
          otherwise).
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

    @Option(name: .customLong("require-focus-id"), help: ArgumentHelp("Type only when the field with this id already has focus; exit 2 otherwise.", valueName: "id"))
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

    /// What `ensureFocus` learnt: the password-field verdict of a read with no tap after it, for the input session to reuse, and the last tree it read.
    struct FocusCheck {
        var secure: KnownSecureFocus?
        var tree: UITree?
    }

    /// `--into-*` taps the field and waits for focus; `--require-focus-id` checks it; plain text needs a field with focus.
    /// Each throws before any text is sent.
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
    ) async throws -> FocusCheck {
        let simulator = device.platform == .ios && !device.isPhysicalIOSDevice
        guard requireFocusID != nil || intoQuery != nil else {
            return try await Self.checkTextFocus(
                readTree: { try await backend.accessibilityTree(for: device) }, device: device, clock: clock, warn: warn, refusingSecureTarget: secureRefusal
            )
        }
        if let requireFocusID {
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
            return FocusCheck(tree: tree)
        }
        guard let query = intoQuery else { return FocusCheck() }
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
        let deadline = clock.now() + Self.focusTimeout
        var last: UITree?
        repeat {
            try await clock.sleep(Self.focusPoll)
            if let tree = try? await backend.accessibilityTree(for: device) {
                last = tree
                if Self.hasFocus(field, query: query, in: tree, keyboardOnly: simulator && !keyboardAlreadyUp) {
                    logger.info().log("\(query.selectorDescription) has focus")
                    return FocusCheck(tree: tree)
                }
            }
        } while clock.now() < deadline
        // A tree that names no focused element at all cannot tell which field the tap focused.
        if keyboardAlreadyUp, let last, !last.roots.flatMap({ $0.flattened() }).contains(where: { $0.state.focused == true }) {
            warn("the keyboard was already up, so the iOS simulator cannot confirm which field has focus; check with assert --has-value.")
            logger.info().log("Tapped \(query.selectorDescription); focusCheck: unproven")
            return FocusCheck(tree: last)
        }
        let noKeyboard = simulator && !keyboardAlreadyUp
            ? " (no keyboard appeared, and the field does not report focus; with the simulator's hardware keyboard connected, no keyboard shows)"
            : ""
        throw CLIError(
            errorDescription: "Tapped \(query.selectorDescription), but it did not take focus within \(Int(Self.focusTimeout)) s\(noKeyboard). No text was typed.",
            reason: .focusNotConfirmed,
            hint: "offsider describe-ui --summary --device \(device.rawValue)"
        )
    }

    /// Plain text: a password field refuses an argument, and nothing goes out unless a field has focus, since keys reaching no field can act as app shortcuts.
    /// A physical iPhone's runner refuses typing with no keyboard focus itself, so only its password field is checked here.
    @MainActor
    static func checkTextFocus(
        readTree: @MainActor () async throws -> UITree,
        device: DeviceID,
        clock: PollClock,
        warn: @MainActor (String) -> Void,
        refusingSecureTarget secureRefusal: CLIError?,
        keys: Bool = false
    ) async throws -> FocusCheck {
        if device.isPhysicalIOSDevice {
            guard let secureRefusal else { return FocusCheck() }
            guard let tree = try? await readTree() else { return FocusCheck(secure: .unknown) }
            if tree.secureFocus == .secureFocused { throw secureRefusal }
            return FocusCheck(secure: .notSecure, tree: tree)
        }
        var tree: UITree
        do {
            tree = try await readTree()
        } catch where device.platform == .android {
            // An unreadable screen does not block typing: Android still sends a password field's text through the helper.
            warn("Offsider could not read the screen to check that a field has focus, so the \(keys ? "keys" : "text") went out unchecked.")
            return FocusCheck(secure: secureRefusal == nil ? nil : .unknown)
        }
        // A field a tap has just focused can take a moment to say so.
        let deadline = clock.now() + focusTimeout / 2
        while !TextFocus.read(tree).takesText, clock.now() < deadline {
            try await clock.sleep(focusPoll)
            guard let next = try? await readTree() else { break }
            tree = next
        }
        let secure = tree.secureFocus == .secureFocused
        if let secureRefusal, secure { throw secureRefusal }
        let focus = TextFocus.read(tree)
        guard focus.takesText else { throw noFocusRefusal(focus, in: tree, device: device, keys: keys) }
        return FocusCheck(secure: secure ? .secure : .notSecure, tree: tree)
    }

    /// Keys with no field to take them can reach the app as shortcuts: a React Native dev build reloads on r.
    static func noFocusRefusal(_ focus: TextFocus, in tree: UITree, device: DeviceID, keys: Bool = false) -> CLIError {
        let sent = keys ? "pressed no keys" : "typed nothing"
        let what: String
        switch focus {
        case .notEditable(let node):
            what = "Input focus is on \(MatchSummary(node, viewport: tree.viewport).text), which takes no text (an app's own keypad takes taps, not keys)"
        case .unlisted:
            what = "The keyboard is up, but no text field the screen lists has focus (an app's own keypad often hides its field, and takes taps, not keys)"
        default:
            what = "No text field has focus"
        }
        return CLIError(
            errorDescription: "\(what), so Offsider \(sent): keys that reach no field can act as app shortcuts, and a React Native dev build reloads on r. Tap the field first, or use `offsider type --into-id <id>`.",
            reason: .noFocusedField,
            hint: "offsider describe-ui --summary --device \(device.rawValue)"
        )
    }

    /// The focused editable field, else any focused element.
    static func focusedField(in tree: UITree) -> UINode? {
        let focused = tree.roots.flatMap { $0.flattened() }.filter { $0.state.focused == true }
        return focused.first { $0.role.isTextInput } ?? focused.first
    }

    /// The field, or a focused field inside its frame, has focus. With `keyboardOnly`, on an iOS simulator whose tree names no focused element,
    /// a keyboard that shows while the field is still on screen counts too.
    static func hasFocus(_ field: UINode?, query: AccessibilityQuery, in tree: UITree, keyboardOnly: Bool) -> Bool {
        let nodes = tree.roots.flatMap { $0.flattened() }
        let focused = nodes.filter { $0.state.focused == true }
        let fieldFocused = focused.contains { node in
            if let id = field?.normalizedID { return node.normalizedID == id }
            guard let frame = field?.frame, let focusedFrame = node.frame else { return query.field(of: node) != nil }
            return frame.intersection(focusedFrame) != nil
        }
        if fieldFocused { return true }
        guard keyboardOnly, focused.isEmpty else { return false }
        let keyboard = nodes.contains { $0.role == .keyboard }
        let stillThere = !AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: nil).onScreen.isEmpty
        return keyboard && stillThere
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
        if !throughSession { try Self.checkIOSText(inputText, logger: logger) }
        let secureRefusal = refusingSecureArgument ? Self.secureFieldRefusal(device: device) : nil
        let focus = try await ensureFocus(backend: backend, device: device, logger: logger, beforeTap: { tree in
            if progress != nil, case .appearing(let id) = verification.mode {
                try Verifier.refuseIfOnScreen(id, in: tree)
            }
        }, refusingSecureTarget: secureRefusal) { event in
            try await backend.performTracked(event, on: device)
        }
        logger.info().log("Typing \(inputText.count) character\(inputText.count == 1 ? "" : "s")")

        if throughSession {
            try await InputSecrecy.$fromArgument.withValue(refusingSecureArgument) {
                try await InputSecrecy.$knownFocus.withValue(focus.secure) {
                    try await typeThroughSession(inputText, backend: backend, device: device, progress: progress)
                }
            }
            return
        }

        let paced = ReactNativeBundle.isFront(in: focus.tree)
        let hidEvents = try Self.iosEvents(for: inputText, replacing: replace, paced: paced)
        logger.info().log("Performing HID event sequence for text typing\(paced ? ", paced for React Native" : "")")

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

    /// Checked before any focus tap, so text the HID keyboard cannot type sends nothing.
    static func checkIOSText(_ text: String, logger: OffsiderLogger) throws {
        do {
            try TextToHIDEvents.checkSupported(text)
        } catch {
            logger.error().log("Text conversion failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// A React Native field that sets its text from each change can drop or reorder keys that arrive faster than its JavaScript runs.
    static let reactNativeKeyGap: TimeInterval = 0.03

    /// iOS key events: with `replacing`, Command-A and Backspace first, in the same composite as the typing; `paced` waits between characters.
    static func iosEvents(for text: String, replacing: Bool, paced: Bool = false) throws -> [InputEvent] {
        let typed: [InputEvent]
        if paced {
            try TextToHIDEvents.checkSupported(text)
            typed = try text.enumerated().flatMap { index, character in
                (index > 0 ? [InputEvent.delay(reactNativeKeyGap)] : []) + (try TextToHIDEvents.convertTextToHIDEvents(String(character)))
            }
        } else {
            typed = try TextToHIDEvents.convertTextToHIDEvents(text)
        }
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
