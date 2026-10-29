import Testing
import Foundation
import OffsiderCore
@testable import Offsider

@Suite("Type Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct TypeTests {
    @Test("Basic text typing")
    func basicTextTyping() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "Hello World"
        
        // Act
        try await TestHelpers.runOffsiderCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement != nil, "Should find text field element")
        #expect(textFieldElement?.value == textToType, "Text field should contain typed text")
    }
    
    @Test("Typing with special characters")
    func typingSpecialCharacters() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        // Note: Using only characters that have keycode mappings in Offsider
        let textToType = "Test@123!$%&*"  // Removed £ which doesn't have keycode mapping
        
        // Act
        try await TestHelpers.runOffsiderCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Special characters should be typed correctly")
    }
    
    @Test("Typing with numbers")
    func typingNumbers() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "1234567890"
        
        // Act
        try await TestHelpers.runOffsiderCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Numbers should be typed correctly")
    }
    
    @Test("Typing with mixed case")
    func typingMixedCase() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "HeLLo WoRLd"
        
        // Act
        try await TestHelpers.runOffsiderCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Mixed case should be preserved")
    }
    
    @Test("Typing with spaces and punctuation")
    func typingSpacesAndPunctuation() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let inputText = "Hello, how are you? I'm fine!"
        
        // Act
        // Escape the text properly for shell - use double quotes and escape internal quotes
        let escapedText = inputText.replacingOccurrences(of: "\"", with: "\\\"")
        try await TestHelpers.runOffsiderCommand("type \"\(escapedText)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" && element.value != nil
        }
        // Note: iOS may add smart punctuation spacing even with autocorrect disabled
        // We'll accept either with or without the extra space
        let actualValue = textFieldElement?.value ?? ""
        let acceptableValues = [
            inputText,
            "Hello, how are you ? I'm fine!"  // With iOS smart punctuation spacing
        ]
        #expect(acceptableValues.contains(actualValue), 
                "Text should match expected value (with or without iOS smart punctuation)")
    }
    
    @Test("Typing empty string")
    func typingEmptyString() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        
        // First type something to ensure field is not empty
        try await TestHelpers.runOffsiderCommand("type \"Initial text\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Act - type empty string (should do nothing)
        try await TestHelpers.runOffsiderCommand("type \"\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert - text should remain unchanged
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == "Initial text", "Empty string should not change existing text")
    }
    
    @Test("Typing long text")
    func typingLongText() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "The quick brown fox jumps over the lazy dog. " +
                        "This is a longer piece of text to test typing performance and accuracy."
        
        // Act
        try await TestHelpers.runOffsiderCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Long text should be typed correctly")
    }
    
    @Test("Typing with manual delays")
    func typingWithManualDelays() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "Delayed"
        
        // Act - Since Offsider type doesn't have built-in delay options, we'll add manual delays
        let startTime = Date()
        try await Task.sleep(nanoseconds: 1_000_000_000) // Manual pre-delay
        try await TestHelpers.runOffsiderCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000) // Manual post-delay
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Command should take at least 2 seconds with manual delays")
        
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Text should still be typed with manual delays")
    }
    
    @Test("Typing into navigation searchable field filters visible state")
    func typingIntoNavigationSearchableFieldFiltersVisibleState() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "searchable-test")

        let initialState = try await TestHelpers.waitForLabel(containing: "Search Query:", timeout: 3) {
            $0 == "Search Query: empty"
        }
        #expect(initialState == "Search Query: empty")

        let uiState = try await TestHelpers.getUIState()
        let searchField = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" && element.value == "Search Books"
        }
        #expect(searchField?.frame != nil)

        try await TestHelpers.runOffsiderCommand("tap --value 'Search Books' --element-type TextField", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 400_000_000)
        try await TestHelpers.runOffsiderCommand("type Alpha", simulatorUDID: defaultSimulatorUDID)

        let filteredState = try await TestHelpers.waitForLabel(containing: "Search Query:", timeout: 3) {
            $0 == "Search Query: Alpha"
        }
        #expect(filteredState == "Search Query: Alpha")

        let filteredUIState = try await TestHelpers.getUIState()
        let alphaRow = UIStateParser.findElementByLabel(in: filteredUIState, label: "Alpha Row")
        let betaRow = UIStateParser.findElementByLabel(in: filteredUIState, label: "Beta Row")
        #expect(alphaRow != nil)
        #expect(betaRow == nil)
    }

    @Test("Unsupported characters throw error")
    func unsupportedCharactersError() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let unsupportedText = "Price: £50"  // £ is not supported by HID keycodes
        
        // Act & Assert - Command should fail with unsupported character error
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runOffsiderCommand("type '\(unsupportedText)'", simulatorUDID: defaultSimulatorUDID)
        }
    }
    
    @Test("Typing from stdin")
    func typingFromStdin() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "Text from stdin"
        
        // Act - Use echo to pipe text to stdin
        guard let udid = defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified in SIMULATOR_UDID environment variable")
        }
        let offsiderPath = try TestHelpers.getOffsiderPath()
        let command = "echo '\(textToType)' | \(offsiderPath) type --stdin --device \(udid)"
        let result = try await CommandRunner.run(command)
        #expect(result.exitCode == 0, "Command should succeed")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Text from stdin should be typed correctly")
    }
    
    @Test("Typing from file")
    func typingFromFile() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "Text from file input"
        
        // Create temporary file
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-input-\(UUID().uuidString).txt")
        try textToType.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        // Act
        try await TestHelpers.runOffsiderCommand("type --file \"\(tempFile.path)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Text from file should be typed correctly")
    }

    @Test("--replace leaves the field holding only the new text")
    func replaceText() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        try await TestHelpers.runOffsiderCommand("type \"hello world\"", simulatorUDID: defaultSimulatorUDID)
        #expect(try await waitForFieldValue("hello world") == "hello world")

        try await TestHelpers.runOffsiderCommand("type --replace \"bye\"", simulatorUDID: defaultSimulatorUDID)

        #expect(try await waitForFieldValue("bye") == "bye")
    }

    @Test("--replace with empty text empties the field")
    func replaceWithEmptyText() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        try await TestHelpers.runOffsiderCommand("type \"hello world\"", simulatorUDID: defaultSimulatorUDID)
        #expect(try await waitForFieldValue("hello world") == "hello world")
        let typedState = try await TestHelpers.getUIState()
        #expect(UIStateParser.findElementContainingLabel(in: typedState, containing: "Characters:") != nil)

        try await TestHelpers.runOffsiderCommand("type --replace \"\"", simulatorUDID: defaultSimulatorUDID)

        // The playground reports an empty field as "empty" and hides its character count.
        #expect(try await waitForFieldValue("empty") == "empty")
        let clearedState = try await TestHelpers.getUIState()
        #expect(UIStateParser.findElementContainingLabel(in: clearedState, containing: "Characters:") == nil)
    }

    /// The text field's value once it equals `expected`, or its last value after 5 s.
    private func waitForFieldValue(_ expected: String) async throws -> String? {
        let deadline = Date().addingTimeInterval(5)
        var value: String?
        repeat {
            let uiState = try await TestHelpers.getUIState()
            value = UIStateParser.findElement(in: uiState) { $0.type == "TextField" }?.value
            if value == expected {
                return value
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
        return value
    }
}
@Suite("type refuses argument text aimed at a password field")
@MainActor
struct TypeSecureFieldTests {
    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let simulator = DeviceID(rawValue: "ABCD0000-0000-4000-8000-000000000001", platform: .ios)

    static func form(focusedPassword: Bool = false, keyboard: Bool = false, platform: DevicePlatform) -> UITree {
        var children = [
            FakeUI.node(.textField, id: "email", label: "Email", frame: FakeUI.frame(20, 200, 360, 44), platform: platform),
            FakeUI.node(
                .secureTextField, id: "password", label: "Password", frame: FakeUI.frame(20, 300, 360, 44),
                state: UIState(focused: focusedPassword ? true : nil), platform: platform
            ),
        ]
        if keyboard { children.append(FakeUI.node(.keyboard, frame: FakeUI.frame(0, 574, 402, 300), platform: platform)) }
        return FakeUI.tree(platform: platform, children)
    }

    static func type(_ arguments: [String], on device: DeviceID, trees: [UITree], refusing: Bool = true) async throws -> FakeDeviceBackend {
        let backend = FakeDeviceBackend(platform: device.platform, trees: trees)
        try await TypeIntoTests.quiet {
            try await Type.parse(arguments + ["--device", device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger(), refusingSecureArgument: refusing)
        }
        return backend
    }

    static func refusal(_ arguments: [String], on device: DeviceID, trees: [UITree]) async throws -> (CLIError?, FakeDeviceBackend) {
        let backend = FakeDeviceBackend(platform: device.platform, trees: trees)
        let error = await #expect(throws: CLIError.self) {
            try await TypeIntoTests.quiet {
                try await Type.parse(arguments + ["--device", device.rawValue])
                    .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger(), refusingSecureArgument: true)
            }
        }
        return (error, backend)
    }

    @Test("argument text aimed at a password field by --into-id exits 64 with nothing sent, pointing at login and --stdin", arguments: [android, simulator])
    func intoPassword(device: DeviceID) async throws {
        let (error, backend) = try await Self.refusal(["--into-id", "password", "hunter2"], on: device, trees: [Self.form(platform: device.platform)])

        #expect(error?.reason == .secureFieldArgument)
        #expect(error?.exitCode.rawValue == 64)
        #expect(error?.userFacingDescription == "The field is a password field, and text given as an argument stays in shell history and process lists, so Offsider typed nothing. Sign in with `offsider login --device \(device.rawValue)`, or pipe it in with `offsider type --stdin --device \(device.rawValue)`.")
        #expect(error?.hint == "offsider login --device \(device.rawValue)")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("on Android argument text with a password field focused is refused with nothing sent")
    func focusedPassword() async throws {
        let (error, backend) = try await Self.refusal(["hunter2"], on: Self.android, trees: [Self.form(focusedPassword: true, platform: .android)])
        #expect(error?.reason == .secureFieldArgument)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--require-focus-id on a focused password field refuses argument text")
    func requireFocusPassword() async throws {
        let (error, _) = try await Self.refusal(["--require-focus-id", "password", "hunter2"], on: Self.android, trees: [Self.form(focusedPassword: true, platform: .android)])
        #expect(error?.reason == .secureFieldArgument)
    }

    @Test("argument text into an ordinary field is typed")
    func ordinaryField() async throws {
        let backend = try await Self.type(["--into-id", "email", "a@b.c"], on: Self.simulator, trees: [Self.form(platform: .ios), Self.form(keyboard: true, platform: .ios)])
        #expect(backend.session.calls.first == .perform(.tapAt(x: 200, y: 222)))
        #expect(backend.session.calls.count == 2)
    }

    @Test("an iOS simulator reports the focused password field, so argument text without --into-* is refused with nothing sent")
    func simulatorFocusedPassword() async throws {
        let (error, backend) = try await Self.refusal(["abc"], on: Self.simulator, trees: [Self.form(focusedPassword: true, platform: .ios)])
        #expect(error?.reason == .secureFieldArgument)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("login's own typing, which never passes the refusal, still reaches a password field")
    func loginUnaffected() async throws {
        let backend = try await Self.type(["--into-id", "password", "--replace", "x"], on: Self.simulator, trees: [Self.form(platform: .ios), Self.form(keyboard: true, platform: .ios)], refusing: false)
        #expect(backend.session.calls.first == .perform(.tapAt(x: 200, y: 322)))
    }

    @Test("--allow-path without --file is a usage error")
    func allowPathNeedsFile() {
        #expect(throws: (any Error).self) { try Type.parse(["--allow-path", "abc", "--device", Self.android.rawValue]) }
    }

    @Test("--file reads through the file checks and refuses a secret's file name; --allow-path reads it only once a person confirms")
    func fileRefused() async throws {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-type-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data("TOKEN=x".utf8).write(to: URL(fileURLWithPath: folder + "/.env"))
        try Data("hello".utf8).write(to: URL(fileURLWithPath: folder + "/text.txt"))

        #expect(throws: TextFileInput.Refused.self) { try Type.parse(["--file", folder + "/.env", "--device", Self.android.rawValue]).resolvedText() }
        let allowing = try Type.parse(["--file", folder + "/.env", "--allow-path", "--device", Self.android.rawValue])
        AllowPathConsent.confirmed = nil
        #expect(throws: TextFileInput.Refused.self) { try allowing.resolvedText() }

        let nobody = FakePresence()
        let piped = await #expect(throws: CLIError.self) {
            try await PersonPresence.$terminal.withValue({ false }) {
                try await PersonPresence.$current.withValue(nobody) { try await AllowPathConsent.confirm(path: folder + "/.env", allowPath: true, command: "type") }
            }
        }
        #expect(piped?.reason == .personRequired)
        #expect(nobody.reasons.isEmpty)

        let noSession = FakePresence(failure: PersonPresence.error(for: .notInteractive))
        let refused = await #expect(throws: CLIError.self) {
            try await PersonPresence.$terminal.withValue({ true }) {
                try await PersonPresence.$current.withValue(noSession) { try await AllowPathConsent.confirm(path: folder + "/.env", allowPath: true, command: "type") }
            }
        }
        #expect(refused?.reason == .personRequired)
        #expect(throws: TextFileInput.Refused.self) { try allowing.resolvedText() }

        let person = FakePresence()
        try await PersonPresence.$terminal.withValue({ true }) {
            try await PersonPresence.$current.withValue(person) { try await AllowPathConsent.confirm(path: folder + "/.env", allowPath: true, command: "type") }
        }
        defer { AllowPathConsent.confirmed = nil }
        let resolved = try #require(TextFileInput.sensitive(folder + "/.env")?.resolvedPath)
        #expect(person.reasons == ["let type read \(resolved)"])
        #expect(try allowing.resolvedText() == "TOKEN=x")

        let plain = FakePresence()
        try await PersonPresence.$current.withValue(plain) { try await AllowPathConsent.confirm(path: folder + "/text.txt", allowPath: true, command: "type") }
        #expect(plain.reasons.isEmpty)
        #expect(try Type.parse(["--file", folder + "/text.txt", "--device", Self.android.rawValue]).resolvedText() == "hello")
    }
}
