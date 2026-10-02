import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// Records events; a drag moves the stub slider to wherever the test says a drag lands.
@MainActor
private final class DragSession: InputSession {
    let device = DeviceID(rawValue: "emulator-5556", platform: .android)
    var onPerform: (InputEvent) -> Void = { _ in }
    private(set) var events: [InputEvent] = []

    func perform(_ event: InputEvent) async throws {
        events.append(event)
        onPerform(event)
    }

    func close() async {}
}

/// An Android-like backend whose slider shows `percent` and whose range action answers from a script.
@MainActor
private final class RangeActionBackend: AccessibilityActionPerforming {
    var percent: Double
    var outcomes: [RangeActionOutcome]
    private(set) var actions: [(fraction: Double, node: UINode)] = []
    private(set) var treeReads = 0
    let session = DragSession()

    init(percent: Double, outcomes: [RangeActionOutcome], dragLandsAt: Double? = nil) {
        self.percent = percent
        self.outcomes = outcomes
        session.onPerform = { [unowned self] _ in
            if let dragLandsAt { self.percent = dragLandsAt }
        }
    }

    var platform: DevicePlatform { .android }
    func prepare() async throws {}
    func listDevices() async throws -> [DeviceSummary] { [] }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Stub") }

    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        treeReads += 1
        let shown = percent.rounded() == percent ? String(Int(percent)) : String(percent)
        let slider = UINode(
            role: .slider, id: "volume", label: "Volume", value: "\(shown)%",
            frame: UIFrame(x: 20, y: 400, width: 360, height: 20),
            native: .android(AndroidNativeAttributes(className: "android.widget.SeekBar"))
        )
        let button = UINode(
            role: .button, id: "submit", label: "Submit", frame: UIFrame(x: 20, y: 500, width: 100, height: 40),
            native: .android(AndroidNativeAttributes(className: "android.widget.Button"))
        )
        let root = UINode(
            role: .application, label: "Playground", frame: UIFrame(x: 0, y: 0, width: 400, height: 800),
            native: .android(AndroidNativeAttributes(className: "android.widget.FrameLayout")), children: [slider, button]
        )
        return UITree(platform: .android, device: id.rawValue, roots: [root])
    }

    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { nil }
    func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] { points }
    func openInputSession(for id: DeviceID) async throws -> any InputSession { session }
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {}
    func screenshotPNG(for id: DeviceID) async throws -> Data { Data() }
    func volatileScreenBands(for id: DeviceID) async -> ScreenBands { ScreenBands(top: 0, bottom: 0) }

    func setRangeValue(_ fraction: Double, of node: UINode, on id: DeviceID) async throws -> RangeActionOutcome {
        actions.append((fraction, node))
        let outcome = outcomes.isEmpty ? .unsupported(reason: "nothing scripted") : outcomes.removeFirst()
        if case .performed(let reachable) = outcome {
            percent = (reachable * 10_000).rounded() / 100
        }
        return outcome
    }
}

@Suite("Slider on Android")
@MainActor
struct SliderCommandAndroidTests {
    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    private static func set(_ arguments: [String], on backend: RangeActionBackend) async throws -> String {
        try await Slider.parse(arguments + ["--device", device.rawValue])
            .setSlider(on: SliderTarget(backend: backend, device: device), logger: OffsiderLogger())
    }

    @Test("a performed action skips the drag and is verified against the tree")
    func performedSkipsDrag() async throws {
        let backend = RangeActionBackend(percent: 25, outcomes: [.performed(reachable: 0.4)])
        let line = try await Self.set(["--id", "volume", "--value", "40"], on: backend)

        #expect(line == "✓ Slider set to 40 successfully (value: 40%)")
        #expect(backend.actions.map(\.fraction) == [0.4])
        #expect(backend.actions.first?.node.id == "volume")
        #expect(backend.session.events.isEmpty)
    }

    @Test("a stale slider is found again once and set from the fresh tree")
    func staleOnce() async throws {
        let backend = RangeActionBackend(percent: 25, outcomes: [.stale, .performed(reachable: 0.75)])
        let line = try await Self.set(["--label", "Volume", "--value", "75"], on: backend)

        #expect(line == "✓ Slider set to 75 successfully (value: 75%)")
        #expect(backend.actions.count == 2)
        #expect(backend.treeReads >= 3, "the selector read, one fresh read, then the read-back")
    }

    @Test("a slider stale twice fails, naming the selector")
    func staleTwice() async throws {
        let backend = RangeActionBackend(percent: 25, outcomes: [.stale, .stale])
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.set(["--id", "volume", "--value", "40"], on: backend)
        }
        #expect(error?.userFacingDescription == "The slider matched by --id 'volume' changed while Offsider was setting it. Retry when the screen is still.")
        #expect(backend.session.events.isEmpty)
    }

    @Test("an unsupported action falls back to the drag")
    func unsupportedDrags() async throws {
        let backend = RangeActionBackend(percent: 25, outcomes: [.unsupported(reason: "no ACTION_SET_PROGRESS")], dragLandsAt: 60)
        let line = try await Self.set(["--id", "volume", "--value", "60"], on: backend)

        #expect(line == "✓ Slider set to 60 successfully (value: 60%)")
        #expect(backend.session.events.count == 1)
        guard case .composite(let steps)? = backend.session.events.first else {
            Issue.record("expected one composite drag")
            return
        }
        #expect(steps.first == .touch(direction: .down, x: 110, y: 410))
    }

    @Test("a control whose steps cannot show the request reports the nearest step it reached")
    func nearestStep() async throws {
        let backend = RangeActionBackend(percent: 25, outcomes: [.performed(reachable: 0.78)])
        let line = try await Self.set(["--id", "volume", "--value", "78.25"], on: backend)

        #expect(line == "✓ Slider set to 78 (the nearest step to 78.25) successfully (value: 78%)")
    }

    @Test("a target that is not a slider fails before any action")
    func notASlider() async throws {
        let backend = RangeActionBackend(percent: 25, outcomes: [.performed(reachable: 0.4)])
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.set(["--id", "submit", "--value", "40"], on: backend)
        }
        #expect(error?.userFacingDescription.contains("Matched element is not a slider (type: Button)") == true)
        #expect(backend.actions.isEmpty)
    }
}
