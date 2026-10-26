import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Describe UI Command Surface Tests")
struct DescribeUICommandSurfaceTests {
    @Test("--point appears in describe-ui --help")
    func describeUIHelpIncludesPoint() async throws {
        let result = try await TestHelpers.runOffsiderCommand("describe-ui --help")
        #expect(result.output.contains("--point <x,y>"))
    }

    @Test("--point appears in help describe-ui")
    func helpDescribeUIIncludesPoint() async throws {
        let result = try await TestHelpers.runOffsiderCommand("help describe-ui")
        #expect(result.output.contains("--point <x,y>"))
    }

    @Test("Invalid --point format fails with guidance")
    func invalidPointFormatFails() async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("describe-ui --device invalid --point nope")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("--point must be in the form x,y using non-negative numbers."))
    }
}

@Suite("Describe UI Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct DescribeUITests {
    @Test("Basic describe-ui returns valid JSON")
    func basicDescribeUI() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        let uiState = try await TestHelpers.getUIState()
        
        // Assert - Should have basic structure (which means JSON was parsed successfully)
        #expect(uiState.type != "", "Root element should have a type")
    }

    @Test("Describe-ui prints the versioned neutral envelope")
    func describeUIPrintsNeutralEnvelope() async throws {
        let simulatorUDID = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test", simulatorUDID: simulatorUDID)

        let result = try await TestHelpers.runOffsiderCommand("describe-ui", simulatorUDID: simulatorUDID)
        let envelope = try UIStateParser.parseDescribeUIEnvelope(result.output)
        let screen = try #require(envelope.screen)
        let application = try #require(envelope.roots.first)

        #expect(envelope.version == 2)
        #expect(envelope.platform == "ios")
        #expect(envelope.device == simulatorUDID)
        #expect(screen.width > 0 && screen.height > 0)
        #expect(application.role == "application")
        #expect(application.native.type == "Application")
        #expect(UIStateParser.findElement(in: application, withIdentifier: "BackButton")?.role == "button")
    }
    
    @Test("describe-ui --diff prints unchanged on a still screen and the sheet's controls after opening it")
    func describeUIDiff() async throws {
        let simulatorUDID = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "parked-sheet-test", simulatorUDID: simulatorUDID)

        _ = try await TestHelpers.runOffsiderCommand("describe-ui --diff", simulatorUDID: simulatorUDID)
        let still = try await TestHelpers.runOffsiderCommand("describe-ui --diff", simulatorUDID: simulatorUDID)
        #expect(still.output.contains("# unchanged since describe-ui "))

        _ = try await TestHelpers.runOffsiderCommand("tap --id parked-sheet-test-open", simulatorUDID: simulatorUDID)
        try await Task.sleep(for: .seconds(1))
        let opened = try await TestHelpers.runOffsiderCommand("describe-ui --diff", simulatorUDID: simulatorUDID)
        #expect(opened.output.contains("# changes since tap "))
        #expect(opened.output.contains("added button \"Apply Filters\" id=parked-sheet-test-apply"))
    }

    @Test("Describe-ui captures UI hierarchy")
    func describeUIHierarchy() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        let uiState = try await TestHelpers.getUIState()
        
        // Assert - Should have basic structure
        #expect(uiState.type != "", "Root element should have a type")
        #expect(uiState.children != nil, "Root element should have children")
        #expect(uiState.children?.count ?? 0 > 0, "Should have at least one child element")
    }

    @Test("Describe-ui exposes SwiftUI TabView tabs as real elements")
    func describeUIExposesSwiftUITabViewTabsAsRealElements() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tab-view-test")

        let uiState = try await TestHelpers.getUIState()
        let homeTab = UIStateParser.findElementByLabel(in: uiState, label: "Home")
        let settingsTab = UIStateParser.findElementByLabel(in: uiState, label: "Settings")

        #expect(homeTab?.type == "RadioButton")
        #expect(homeTab?.frame != nil)
        #expect(settingsTab?.type == "RadioButton")
        #expect(settingsTab?.frame != nil)
    }

    @Test("Describe-ui marks the selected tab selected and the others not, and follows a tap")
    func describeUIReportsSelectedTab() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tab-view-test")

        let before = try await TestHelpers.getUIState()
        #expect(UIStateParser.findElementByLabel(in: before, label: "Home")?.state.selected == true)
        #expect(UIStateParser.findElementByLabel(in: before, label: "Settings")?.state.selected == false)

        try await TestHelpers.runOffsiderCommand("tap --label Settings --element-type radioButton", simulatorUDID: try TestHelpers.requireSimulatorUDID())
        _ = try await TestHelpers.waitForLabel(containing: "Current Tab:", timeout: 3) { $0 == "Current Tab: Settings" }

        let after = try await TestHelpers.getUIState()
        #expect(UIStateParser.findElementByLabel(in: after, label: "Home")?.state.selected == false)
        #expect(UIStateParser.findElementByLabel(in: after, label: "Settings")?.state.selected == true)
    }

    @Test("Describe-ui exposes navigation searchable field")
    func describeUIExposesNavigationSearchableField() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "searchable-test")

        let uiState = try await TestHelpers.getUIState()
        let searchField = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" && element.value == "Search Books"
        }

        #expect(searchField?.frame != nil)
    }

    @Test("Describe-ui exposes toolbar segmented picker and navigation back button")
    func describeUIExposesToolbarPickerAndBackButton() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "toolbar-picker-test")

        let uiState = try await TestHelpers.getUIState()
        let backButton = UIStateParser.findElement(in: uiState, withIdentifier: "BackButton")
        let allOption = UIStateParser.findElementByLabel(in: uiState, label: "All")
        let unreadOption = UIStateParser.findElementByLabel(in: uiState, label: "Unread")
        let readOption = UIStateParser.findElementByLabel(in: uiState, label: "Read")

        #expect(backButton?.type == "Button")
        #expect(allOption?.type == "RadioButton")
        #expect(unreadOption?.type == "RadioButton")
        #expect(readOption?.type == "RadioButton")
    }

    @Test("Describe-ui --point returns the targeted element")
    func describeUIAtPoint() async throws {
        let simulatorUDID = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test", simulatorUDID: simulatorUDID)

        let uiState = try await TestHelpers.getUIState(simulatorUDID: simulatorUDID)
        guard let backButton = UIStateParser.findElement(in: uiState, withIdentifier: "BackButton"),
              let frame = backButton.frame
        else {
            throw TestError.elementNotFound("BackButton with frame was not found in describe-ui output")
        }

        let centerX = frame.x + (frame.width / 2)
        let centerY = frame.y + (frame.height / 2)
        let point = "\(centerX),\(centerY)"

        let result = try await TestHelpers.runOffsiderCommand(
            "describe-ui --point \(point)",
            simulatorUDID: simulatorUDID
        )

        let envelope = try UIStateParser.parseDescribeUIEnvelope(result.output)
        let roots = envelope.roots
        #expect(envelope.version == 2)
        #expect(envelope.device == simulatorUDID)
        #expect(roots.count == 1, "Point-based describe-ui should return a single top-level element")

        let targetedElement = try #require(roots.first)
        let targetedFrame = try #require(targetedElement.frame)

        #expect(targetedElement.identifier == "BackButton")
        #expect(targetedElement.label == "Offsider Playground")
        #expect(targetedElement.role == "button")
        #expect(targetedElement.type == "Button")
        #expect(targetedElement.enabled == true)
        #expect(targetedElement.state.checked == nil)
        #expect(targetedElement.native.role == "AXButton")
        #expect(targetedElement.native.roleDescription == "back button")
        #expect(targetedElement.native.contentRequired == false)
        #expect(targetedElement.native.title == nil)
        #expect(targetedElement.native.help == nil)
        #expect(targetedElement.native.subrole == nil)
        #expect(targetedElement.native.axFrame == "{{16, 62}, {44, 44}}")
        #expect(targetedElement.children?.isEmpty == true)
        #expect(targetedElement.native.customActions?.isEmpty == true)
        #expect(targetedFrame.x == 16)
        #expect(targetedFrame.y == 62)
        #expect(targetedFrame.width == 44)
        #expect(targetedFrame.height == 44)
    }
}

@Suite("describe-ui redaction")
@MainActor
struct DescribeUIRedactionTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static let secrets = FakeUI.tree([
        FakeUI.node(.text, id: "otp-banner", label: "Your code is 482913", frame: FakeUI.frame(20, 100, 350, 30)),
        FakeUI.node(.textField, id: "card-field", label: "Card", value: "4111 1111 1111 1111", frame: FakeUI.frame(20, 150, 350, 44)),
        FakeUI.node(.button, id: "sign-in", label: "Sign in", frame: FakeUI.frame(20, 600, 350, 44)),
    ])

    static func login(revealed: Bool, id: String? = "password") -> UITree {
        FakeUI.tree([
            FakeUI.node(revealed ? .textField : .secureTextField, id: id, label: "Password", value: revealed ? "hunter22" : "••••••••", frame: FakeUI.frame(16, 270, 361, 44)),
            FakeUI.node(.button, id: revealed ? "hide" : "show", label: revealed ? "Hide" : "Show", frame: FakeUI.frame(300, 270, 60, 44)),
        ])
    }

    static func describe(_ arguments: [String], on backend: FakeDeviceBackend, config: MaskConfig? = nil) async throws -> String {
        let loaded = config.map { MaskConfigs.Loaded(config: $0, path: "/repo/offsider.mask.json") }
        return try await MaskConfigs.$source.withValue({ loaded }) {
            let route = DeviceRouter.Route(backend: backend, device: device)
            let output = try await DescribeUI.parse(arguments + ["--device", device.rawValue]).describe(on: route)
            await TreeCache.commit(command: "describe-ui", effect: .read, claimed: [], backends: [backend])
            DeviceActivityLedger.current.reset()
            return output
        }
    }

    @Test("codes and card numbers in labels and values are redacted and counted, ids never")
    func textRedacted() async throws {
        let fixture = try TreeCacheFixture()
        let output = try await fixture.run { try await Self.describe(["--format", "text"], on: FakeDeviceBackend(trees: [Self.secrets])) }

        #expect(output.contains(#"text "Your code is [redacted]" id=otp-banner"#))
        #expect(output.contains(#"id=card-field value="[redacted card]""#))
        #expect(output.contains(#"button "Sign in" id=sign-in"#))
        #expect(!output.contains("482913") && !output.contains("4111"))
        #expect(output.hasSuffix("# redacted: 2 values\n"))
    }

    @Test("JSON carries redacted and revealed counts only when something was hidden")
    func jsonCounts() async throws {
        let fixture = try TreeCacheFixture()
        let redacted = try await fixture.run { try await Self.describe([], on: FakeDeviceBackend(trees: [Self.secrets])) }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(redacted.utf8)) as? [String: Any])
        #expect(object["redacted"] as? Int == 2)
        #expect(object["revealed"] as? Int == 0)
        #expect(!redacted.contains("482913") && !redacted.contains("4111"))

        let clean = try await fixture.run { try await Self.describe([], on: FakeDeviceBackend(trees: [Self.login(revealed: false)])) }
        #expect(!clean.contains(#""redacted""#))
    }

    @Test("offsider.mask.json ids and labels hide values, and an id match its label, in the output and the cache")
    func configMasks() async throws {
        let fixture = try TreeCacheFixture()
        let tree = FakeUI.tree([
            FakeUI.node(.text, id: "balance", label: "Balance", value: "$12", frame: FakeUI.frame(20, 100, 350, 30)),
            FakeUI.node(.text, id: "member", label: "Member number", value: "M-77", frame: FakeUI.frame(20, 150, 350, 30)),
            FakeUI.node(.text, id: "note", label: "Note", value: "Hi there", frame: FakeUI.frame(20, 200, 350, 30)),
        ])
        let config = MaskConfig(ids: ["balance"], labels: ["Member number"])
        let output = try await fixture.run { try await Self.describe(["--format", "text"], on: FakeDeviceBackend(trees: [tree]), config: config) }

        #expect(output.contains(#"text "[redacted]" id=balance ("#) && !output.contains("$12"))
        #expect(output.contains(#"text "Member number" id=member value="[redacted]""#))
        #expect(output.contains(#"value="Hi there""#))
        let cached = String(decoding: try #require(FileManager.default.contents(atPath: fixture.path(for: Self.device))), as: UTF8.self)
        #expect(!cached.contains("$12") && !cached.contains("M-77"))
        #expect(cached.contains("Hi there"))
    }

    @Test("a password field shown as plain text at the same id is masked and counted as revealed")
    func revealedByID() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.login(revealed: false), Self.login(revealed: true)])
        let output = try await fixture.run {
            _ = try await Self.describe(["--summary"], on: backend)
            return try await Self.describe(["--format", "text"], on: backend)
        }

        #expect(output.contains(#"textField "Password" id=password value="••••••••""#))
        #expect(!output.contains("hunter22"))
        #expect(output.hasSuffix("# redacted: 1 revealed password field\n"))
        let cached = String(decoding: try #require(FileManager.default.contents(atPath: fixture.path(for: Self.device))), as: UTF8.self)
        #expect(!cached.contains("hunter22"))
    }

    @Test("a revealed field with no id is found by its frame, and the record ends with the boot")
    func revealedByFrame() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.login(revealed: false, id: nil), Self.login(revealed: true, id: nil), Self.login(revealed: true, id: nil)])
        backend.bootMarkerValue = "boot 1"
        let output = try await fixture.run {
            _ = try await Self.describe(["--summary"], on: backend)
            return try await Self.describe(["--format", "text"], on: backend)
        }
        #expect(!output.contains("hunter22"))

        backend.bootMarkerValue = "boot 2"
        let rebooted = try await fixture.run { try await Self.describe(["--format", "text"], on: backend) }
        #expect(rebooted.contains("hunter22"))
    }

    @Test("--diff compares redacted trees, so a redacted value reads as unchanged")
    func diffRedacted() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.secrets])
        let output = try await fixture.run {
            _ = try await Self.describe(["--summary"], on: backend)
            return try await Self.describe(["--diff"], on: backend)
        }
        #expect(output.contains("# unchanged since describe-ui"))
        #expect(!output.contains("4111"))
    }

    // MARK: Cost

    /// A screen of `count` nodes with the labels and values a long list shows: names, prices, dates and ids.
    nonisolated static func syntheticTree(nodes count: Int) -> UITree {
        let rows = (0..<count).map { index in
            FakeUI.node(
                index % 3 == 0 ? .cell : .text, id: "row-\(index)", label: "Item \(index) Example product name",
                value: index % 4 == 0 ? "$\(index).99 AUD, 2026-10-\(index % 28 + 1)" : "Qty \(index % 9)",
                frame: FakeUI.frame(0, Double(index) * 44, 402, 44)
            )
        }
        return FakeUI.tree(rows)
    }

    nonisolated static func medianMilliseconds(runs: Int = 15, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<runs {
            let elapsed = clock.measure(body)
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        return samples.sorted()[runs / 2]
    }

    @Test("redacting a 1,000 and a 5,000 node tree stays within budget", arguments: [(1000, 1.0), (5000, 5.0)])
    nonisolated func redactionCost(nodes: Int, budget: Double) {
        let tree = Self.syntheticTree(nodes: nodes)
        var counted = UITreeRedactionCounts()
        let median = Self.medianMilliseconds { counted = tree.redacted().redaction ?? counted }
        print("offsider bench: redact \(nodes) nodes median \(String(format: "%.3f", median)) ms")
        #expect(counted.isEmpty)
        // The budget holds for release builds (about 0.4 ms and 1.7 ms); a debug build runs several times slower, and one under AddressSanitizer
        // several times slower again, so this guards against a regression of scale rather than the budget itself.
        #expect(median < budget * (Self.sanitized ? 50 : 10))
    }

    /// True when the test process runs under AddressSanitizer, whose runtime exports this symbol.
    nonisolated static let sanitized = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_init") != nil
}
