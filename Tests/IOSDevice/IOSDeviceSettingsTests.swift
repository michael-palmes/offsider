import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("iOS device appearance, content size and orientation")
@MainActor
struct IOSDeviceSettingsTests {
    static let udid = IOSDeviceFixtures.phone
    static let device = DeviceID(rawValue: udid, platform: .ios)

    /// The `--text-size` values from `xcrun devicectl device settings appearance --help` (devicectl 651.13.4).
    static let devicectlTextSizes = """
    extra-small, small, medium, large, extra-large,
    extra-extra-large, extra-extra-extra-large, accessibility-medium,
    accessibility-large, accessibility-extra-large,
    accessibility-extra-extra-large, accessibility-extra-extra-extra-large
    """

    static func backend(replies: [String: String] = [:]) -> (IOSDeviceBackend, FakeDevicectl) {
        let devicectl = FakeDevicectl(replies: replies.mapValues { ProcessCaptureResult(status: 0, stdout: $0, stderr: "") })
        return (IOSDeviceBackend(host: .fake(devicectl)) { _, _ in }, devicectl)
    }

    static func appearanceReply(style: String = "light", textSize: String = "Medium") throws -> String {
        try IOSDeviceFixtures.text("devicectl-info-appearance.json")
            .replacingOccurrences(of: "\"userInterfaceStyle\" : \"light\"", with: "\"userInterfaceStyle\" : \"\(style)\"")
            .replacingOccurrences(of: "\"textSize\" : \"Medium\"", with: "\"textSize\" : \"\(textSize)\"")
    }

    @Test("devicectl's text-size names are Offsider's content-size names, in the same order")
    func textSizeVocabulary() {
        let names = Self.devicectlTextSizes.split { $0 == "," || $0.isWhitespace }.map(String.init)
        #expect(names == ContentSizeCategory.allCases.map(\.rawValue))
    }

    @Test("one appearance read answers the style and the text size from the captured iPad reply")
    func readsCapturedAppearance() async throws {
        let (backend, devicectl) = Self.backend(replies: ["appearance": try IOSDeviceFixtures.text("devicectl-info-appearance.json")])

        #expect(try await backend.appearance(on: Self.device) == .fixed(.light))
        #expect(try await backend.contentSize(on: Self.device) == ContentSizeReading(category: .medium, fontScale: nil))
        #expect(devicectl.calls == Array(repeating: ["device", "info", "appearance", "--device", Self.udid, "--timeout", "20", "--json-output", "-", "-q"], count: 2))
    }

    @Test("dark mode and spaced, camel case and short text size names read as Offsider's names", arguments: [
        ("Accessibility Extra Extra Large", ContentSizeCategory.accessibilityExtraExtraLarge),
        ("extraExtraExtraLarge", .extraExtraExtraLarge),
        ("XS", .extraSmall),
        ("large", .large),
    ])
    func readsTextSizeNames(name: String, expected: ContentSizeCategory) throws {
        let reading = try IOSDeviceSettings.parseAppearance(Data(try Self.appearanceReply(style: "dark", textSize: name).utf8))
        #expect(reading == IOSDeviceAppearance(appearance: .dark, contentSize: expected))
    }

    @Test("a style or text size the device reports but Offsider does not know is a devicectl failure naming the value")
    func unknownReportedValuesRefused() async throws {
        for (reply, value) in [(try Self.appearanceReply(textSize: "Gigantic"), "Gigantic"), (try Self.appearanceReply(style: "automatic"), "automatic")] {
            let (backend, _) = Self.backend(replies: ["appearance": reply])
            let error = await #expect(throws: IOSDeviceError.self) { _ = try await backend.contentSize(on: Self.device) }
            #expect(error?.reason == .commandFailed)
            #expect(error?.message.contains("'\(value)'") == true)
            #expect(error?.hint == "offsider doctor --device \(Self.udid)")
        }
    }

    @Test("an unknown size name is refused before anything reaches the device")
    func unknownRequestedSizeRefused() {
        #expect(throws: DeviceSettingsError.self) { try ContentSizeCategory.parse("gigantic") }
    }

    @Test("setting the appearance sends the mode to devicectl's settings command", arguments: Appearance.allCases)
    func setsAppearance(appearance: Appearance) async throws {
        let (backend, devicectl) = Self.backend()
        try await backend.setAppearance(appearance, on: Self.device)
        #expect(devicectl.calls == [["device", "settings", "appearance", "--device", Self.udid, "--mode", appearance.rawValue, "--timeout", "20", "-q"]])
    }

    @Test("a standard text size is sent alone; an accessibility size also turns Larger Accessibility Sizes on")
    func setsContentSize() async throws {
        let (backend, devicectl) = Self.backend()
        try await backend.setContentSize(.extraLarge, on: Self.device)
        try await backend.setContentSize(.accessibilityLarge, on: Self.device)
        #expect(devicectl.calls == [
            ["device", "settings", "appearance", "--device", Self.udid, "--text-size", "extra-large", "--timeout", "20", "-q"],
            ["device", "settings", "appearance", "--device", Self.udid, "--text-size", "accessibility-large", "--larger-accessibility-sizes", "on", "--timeout", "20", "-q"],
        ])
    }

    @Test("orientation is the display's native turn plus the UI's turn, clockwise in devicectl", arguments: [
        ("devicectl-info-displays.json", "rot0", DeviceOrientation.portrait),
        ("devicectl-info-displays.json", "rot90", .landscapeRight),
        ("devicectl-info-displays.json", "rot180", .portraitUpsideDown),
        ("devicectl-info-displays-ipad.json", "rot0", .landscapeLeft),
        ("devicectl-info-displays-ipad.json", "rot90", .portrait),
    ])
    func readsOrientation(fixture: String, current: String, expected: DeviceOrientation) throws {
        let json = try IOSDeviceFixtures.text(fixture)
            .replacingOccurrences(of: #""currentOrientation" ?: "rot0""#, with: "\"currentOrientation\": \"\(current)\"", options: .regularExpression)
        #expect(IOSDeviceSettings.parseOrientation(displaysJSON: Data(json.utf8)) == expected)
    }

    @Test("without a display the device's own orientation is used, and face up is unknown")
    func orientationWithoutDisplay() {
        func reply(_ orientation: String) -> Data {
            Data(#"{"result": {"displays": [], "orientation": {"currentDeviceOrientation": "\#(orientation)"}}}"#.utf8)
        }
        #expect(IOSDeviceSettings.parseOrientation(displaysJSON: reply("landscapeRight")) == .landscapeRight)
        #expect(IOSDeviceSettings.parseOrientation(displaysJSON: reply("faceUp")) == nil)
    }

    @Test("each orientation read asks devicectl again, and a turn is sent with devicectl's orientation name")
    func orientationReadsFreshAndSets() async throws {
        let (backend, devicectl) = Self.backend(replies: ["displays": try IOSDeviceFixtures.text("devicectl-info-displays-ipad.json")])
        #expect(try await backend.orientation(of: Self.device) == .landscapeLeft)
        try await backend.requestOrientation(.portraitUpsideDown, on: Self.device)
        _ = try await backend.orientation(of: Self.device)

        let read = ["device", "info", "displays", "--device", Self.udid, "--timeout", "20", "--json-output", "-", "-q"]
        #expect(devicectl.calls == [read, ["device", "orientation", "set", "--device", Self.udid, "portraitUpsideDown", "--timeout", "20", "-q"], read])
    }
}
