import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android device controls")
@MainActor
struct AndroidDeviceControlsTests {
    /// Answers the settings commands from a mutable emulator state, as the real shell would.
    final class Emulator: @unchecked Sendable {
        private let lock = NSLock()
        private var _night: String
        private var _fontScale = "null"
        private var _rotation = 0
        private var _accelerometer = "1"
        var accelerometer: String { lock.withLock { _accelerometer } }
        var night: String { lock.withLock { _night } }

        init(night: String = "no") {
            _night = night
        }
        var fontScale: String { lock.withLock { _fontScale } }

        func reply(to service: String) -> FakeAdbServer.Reply {
            lock.withLock {
                let command = service.hasPrefix("shell,v2,raw:") ? String(service.dropFirst("shell,v2,raw:".count)) : service
                if command == AndroidDeviceSettings.readNightMode {
                    return FakeAdbServer.shell(stdout: "Night mode: \(_night)\n")
                }
                if command.hasPrefix("cmd uimode night ") {
                    _night = String(command.dropFirst("cmd uimode night ".count))
                    return FakeAdbServer.shell(stdout: "Night mode: \(_night)\n")
                }
                if command == AndroidDeviceSettings.readFontScale {
                    return FakeAdbServer.shell(stdout: "\(_fontScale)\n")
                }
                if command.hasPrefix("settings put system font_scale ") {
                    _fontScale = String(command.dropFirst("settings put system font_scale ".count))
                    return FakeAdbServer.shell()
                }
                if command.hasPrefix("settings put system accelerometer_rotation 0; settings put system user_rotation "),
                   let rotation = Int(command.suffix(1)) {
                    _rotation = rotation
                    _accelerometer = "0"
                    return FakeAdbServer.shell()
                }
                if command == AutoRotateState.readScript {
                    return FakeAdbServer.shell(stdout: "\(_accelerometer)\n\(_rotation)\n")
                }
                if command.hasPrefix("settings put system accelerometer_rotation ") {
                    _accelerometer = String(command.dropFirst("settings put system accelerometer_rotation ".count))
                    return FakeAdbServer.shell()
                }
                if command.hasSuffix(AndroidDisplayGeometry.probeScript) {
                    let quarter = _rotation % 2 == 1
                    let frame = quarter ? "2424, 1080" : "1080, 2424"
                    return FakeAdbServer.shell(stdout: """
                    Physical size: 1080x2424
                    Physical density: 420
                      Viewport INTERNAL: displayId=0, uniqueId=local:1, port=Optional(0), orientation=\(_rotation), logicalFrame=[0, 0, \(frame)], isActive=[1]
                    """)
                }
                return FakeAdbServer.shell(stderr: "unexpected \(command)", status: 1)
            }
        }
    }

    static func setUp(night: String = "no") throws -> (AndroidBackend, FakeAdbServer, Emulator) {
        let emulator = Emulator(night: night)
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in emulator.reply(to: service) }
        ))
        return (try AndroidBackendTests.backend(server), server, emulator)
    }

    static let device = AndroidBackendTests.device

    @Test("night mode output parses to an appearance, auto and custom to a schedule, and junk to nothing", arguments: [
        ("Night mode: yes\n", AppearanceReading.fixed(.dark)),
        ("Night mode: no", .fixed(.light)),
        ("Night mode: auto\n", .scheduled("auto")),
        ("Night mode: custom_schedule\n", .scheduled("custom")),
        ("cmd: Can't find service: uimode", nil),
    ] as [(String, AppearanceReading?)])
    func nightMode(output: String, expected: AppearanceReading?) {
        #expect(AndroidDeviceSettings.parseNightMode(output) == expected)
    }

    @Test("font_scale output parses, with null and empty meaning the default 1.0", arguments: [
        ("null\n", 1.0),
        ("", 1.0),
        ("1.3\n", 1.3),
        ("abc", nil),
        ("-1", nil),
    ] as [(String, Double?)])
    func fontScale(output: String, expected: Double?) {
        #expect(AndroidDeviceSettings.parseFontScale(output) == expected)
    }

    @Test("appearance is set with cmd uimode night and read back")
    func appearance() async throws {
        let (backend, server, emulator) = try Self.setUp()

        #expect(try await backend.appearance(on: Self.device) == .fixed(.light))
        try await backend.setAppearance(.dark, on: Self.device)

        #expect(server.services.contains("shell,v2,raw:cmd uimode night yes"))
        #expect(emulator.night == "yes")
        #expect(try await backend.appearance(on: Self.device) == .fixed(.dark))
    }

    @Test("content size writes the category's font scale and reads the nearest category back")
    func contentSize() async throws {
        let (backend, server, emulator) = try Self.setUp()

        #expect(try await backend.contentSize(on: Self.device) == ContentSizeReading(category: .large, fontScale: 1.0))
        try await backend.setContentSize(.extraExtraLarge, on: Self.device)

        #expect(server.services.contains("shell,v2,raw:settings put system font_scale 1.3"))
        #expect(emulator.fontScale == "1.3")
        #expect(try await backend.contentSize(on: Self.device) == ContentSizeReading(category: .extraExtraLarge, fontScale: 1.3))
    }

    @Test("a large content size writes a whole 1, not 1.0")
    func largeScaleText() {
        #expect(AndroidDeviceSettings.setFontScale(1.0) == "settings put system font_scale 1")
    }

    @Test("orientation turns auto-rotate off, sets user_rotation and re-probes the display")
    func orientation() async throws {
        let (backend, server, _) = try Self.setUp()

        #expect(try await backend.orientation(of: Self.device) == .portrait)
        try await backend.requestOrientation(.landscapeLeft, on: Self.device)

        #expect(server.services.contains("shell,v2,raw:settings put system accelerometer_rotation 0; settings put system user_rotation 1"))
        #expect(try await backend.orientation(of: Self.device) == .landscapeLeft)
        #expect(try await backend.screenInfo(for: Self.device)?.rotation == .landscapeFlipped)
    }

    @Test("auto-rotate and user_rotation are read in one round trip and auto-rotate is written back on its own")
    func autoRotate() async throws {
        let (backend, _, emulator) = try Self.setUp()

        #expect(try await backend.autoRotateState(on: Self.device) == AutoRotateState(accelerometerRotation: 1, userRotation: 0))
        try await backend.requestOrientation(.landscapeLeft, on: Self.device)
        #expect(try await backend.autoRotateState(on: Self.device) == AutoRotateState(accelerometerRotation: 0, userRotation: 1))
        try await backend.setAccelerometerRotation(1, on: Self.device)
        #expect(emulator.accelerometer == "1")
    }

    @Test("a failing settings command quotes its stderr")
    func failure() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, _ in FakeAdbServer.shell(stderr: "Security exception: denied\n", status: 255) }
        ))
        let backend = try AndroidBackendTests.backend(server)
        let error = await #expect(throws: AndroidError.self) { try await backend.setAppearance(.dark, on: Self.device) }
        #expect(error?.message == "`cmd uimode night yes` failed on emulator-5556: Security exception: denied.")
    }

    @Test("each public orientation's Android rotation names the same coordinate orientation as the display geometry",
          arguments: DeviceOrientation.allCases)
    func rotationAgreesWithGeometry(orientation: DeviceOrientation) {
        let geometry = AndroidDisplayGeometry(
            naturalWidth: 1080, naturalHeight: 2424, logicalWidth: 1080, logicalHeight: 2424,
            rotation: orientation.androidRotation, densityDpi: 420, hasSizeOverride: false
        )
        #expect(geometry.orientation == orientation.coordinateOrientation)
        #expect(DeviceOrientation(androidRotation: orientation.androidRotation) == orientation)
    }

    @Test("the Android backend cannot shake")
    func noShake() {
        let backend: any DeviceBackend = AndroidBackend(host: .live()) { _, _ in }
        #expect(!(backend is any DeviceShaking))
    }
}
