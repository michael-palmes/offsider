import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Key Combo Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct KeyComboTests {
    @Test("Cmd+A selects all text")
    func cmdA() async throws {
        // Arrange - navigate to text input and type some text
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        try await TestHelpers.runOffsiderCommand("type \"hello world\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Act - Cmd+A to select all, then Backspace to delete
        try await TestHelpers.runOffsiderCommand("key-combo --modifiers 227 --key 4", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await TestHelpers.runOffsiderCommand("key 42", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Assert - command flow executed and text field remains discoverable
        let uiState = try await TestHelpers.getUIState()
        let textField = UIStateParser.findElement(in: uiState) { $0.type == "TextField" }
        #expect(textField != nil)
        #expect(
            textField?.value == nil || textField?.value == "" || textField?.value == "empty",
            "Text field should be cleared after Cmd+A then Backspace"
        )
    }

    @Test("Single modifier key combo")
    func singleModifier() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-press")

        // Act - press Cmd+A (modifier 227, key 4)
        try await TestHelpers.runOffsiderCommand("key-combo --modifiers 227 --key 4", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Assert - the key press should have been registered
        let uiState = try await TestHelpers.getUIState()
        let keyPressElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last Key:")
        #expect(keyPressElement != nil, "A key press should have been registered")
    }

    @Test("Multiple modifier key combo")
    func multipleModifiers() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "key-press")

        // Act - press Cmd+Shift+A (modifiers 227,225, key 4)
        try await TestHelpers.runOffsiderCommand("key-combo --modifiers 227,225 --key 4", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Assert - the key press should have been registered
        let uiState = try await TestHelpers.getUIState()
        let keyPressElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Last Key:")
        #expect(keyPressElement != nil, "A key press should have been registered")
    }

    @Test("Empty modifiers fails validation")
    func emptyModifiers() async throws {
        // Act & Assert - Should fail with validation error
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runOffsiderCommand("key-combo --modifiers \"\" --key 4", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Out-of-range modifier fails validation")
    func outOfRangeModifier() async throws {
        // Act & Assert - Modifier keycode 256 is out of valid range (0-255)
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runOffsiderCommand("key-combo --modifiers 256 --key 4", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Out-of-range key fails validation")
    func outOfRangeKey() async throws {
        // Act & Assert - Key 300 is out of valid range (0-255)
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runOffsiderCommand("key-combo --modifiers 227 --key 300", simulatorUDID: defaultSimulatorUDID)
        }
    }

    @Test("Too many modifiers fails validation")
    func tooManyModifiers() async throws {
        // Act & Assert - 9 modifiers exceeds the limit of 8
        let modifiers = Array(repeating: "227", count: 9).joined(separator: ",")
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runOffsiderCommand("key-combo --modifiers \(modifiers) --key 4", simulatorUDID: defaultSimulatorUDID)
        }
    }
}

@Suite("Meta keys on Android phones")
@MainActor
struct SystemKeyGuardTests {
    static let phone = DeviceID(rawValue: "711KPHG0708353", platform: .android)
    static let emulator = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let simulator = DeviceID(rawValue: UUID().uuidString, platform: .ios)

    private func context(_ backend: FakeDeviceBackend, on device: DeviceID) -> BatchContext {
        BatchContext(backend: backend, device: device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 1)
    }

    @Test("Meta+M on a phone is a usage error naming Control and the flag, and opens no input session")
    func comboRefusedOnPhone() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        let command = try KeyCombo.parse(["--modifiers", "227", "--key", "16", "--device", Self.phone.rawValue])

        let error = await #expect(throws: CLIError.self) {
            try await command.perform(on: DeviceRouter.Route(backend: backend, device: Self.phone), logger: OffsiderLogger())
        }

        #expect(error?.reason.exitCode == .usage)
        #expect(error?.userFacingDescription.contains("Nothing was sent") == true)
        #expect(error?.userFacingDescription.contains("--modifiers 224 --key 4") == true)
        #expect(error?.userFacingDescription.contains("--allow-system-keys") == true)
        #expect(backend.openedSessions.isEmpty)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("right Meta as the key itself, in a sequence, or alone is refused on a phone too")
    func otherShapesRefused() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        let route = DeviceRouter.Route(backend: backend, device: Self.phone)
        await #expect(throws: CLIError.self) {
            try await KeyCombo.parse(["--modifiers", "224", "--key", "231", "--device", Self.phone.rawValue]).perform(on: route, logger: OffsiderLogger())
        }
        await #expect(throws: CLIError.self) {
            try await KeySequence.parse(["--keycodes", "4,231,5", "--device", Self.phone.rawValue]).perform(on: route, logger: OffsiderLogger())
        }
        await #expect(throws: CLIError.self) {
            _ = try await Key.parse(["227", "--device", Self.phone.rawValue]).toBatchPrimitives(context: context(backend, on: Self.phone), logger: OffsiderLogger())
        }
        #expect(backend.openedSessions.isEmpty)
    }

    @Test("a batch key-combo step with Meta on a phone fails before the batch sends anything")
    func batchStepRefused() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        let step = try KeyCombo.parse(["--modifiers", "227", "--key", "16", "--device", Self.phone.rawValue])
        await #expect(throws: CLIError.self) {
            _ = try await step.toBatchPrimitives(context: context(backend, on: Self.phone), logger: OffsiderLogger())
        }
        #expect(backend.session.calls.isEmpty)
    }

    @Test("Meta goes to an emulator, to an iOS simulator as Command, and to a phone with --allow-system-keys")
    func allowed() async throws {
        for (device, extra) in [(Self.emulator, [String]()), (Self.simulator, []), (Self.phone, ["--allow-system-keys"])] {
            let backend = FakeDeviceBackend(platform: device.platform, trees: [])
            try await KeyCombo.parse(["--modifiers", "227", "--key", "16", "--device", device.rawValue] + extra)
                .perform(on: DeviceRouter.Route(backend: backend, device: device), logger: OffsiderLogger())
            #expect(backend.session.calls == [.perform(.composite([.keyboard(direction: .down, keyCode: 227), .shortKeyPress(16), .keyboard(direction: .up, keyCode: 227)]))])
        }
    }

    @Test("Control and other keys pass on a phone", arguments: [[224, 4], [225, 226, 230], [4, 40]])
    func otherKeysPass(keys: [Int]) {
        #expect(SystemKeyGuard.refusal(keys: keys, on: Self.phone, allowed: false) == nil)
    }
}
