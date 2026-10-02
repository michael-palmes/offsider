import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Fake device backend")
@MainActor
struct FakeDeviceBackendTests {
    private let device = DeviceID(rawValue: "fake-device", platform: .ios)

    private func screen(_ label: String) -> UITree {
        FakeUI.tree([FakeUI.node(.text, id: "state", label: label, frame: FakeUI.frame(20, 100, 200, 40))])
    }

    private func label(in tree: UITree) -> String? {
        tree.roots.flatMap { $0.flattened() }.first { $0.id == "state" }?.label
    }

    @Test("each read serves the next scripted tree, then holds the last")
    func readsAdvanceThenHold() async throws {
        let backend = FakeDeviceBackend(trees: [screen("one"), screen("two")])

        let labels = [
            label(in: try await backend.accessibilityTree(for: device)),
            label(in: try await backend.accessibilityTree(for: device)),
            label(in: try await backend.accessibilityTree(for: device)),
        ]

        #expect(labels == ["one", "two", "two"])
        #expect(backend.treeReads == 3)
    }

    @Test("advancing on input keeps the tree until an event is performed")
    func inputAdvancesTree() async throws {
        let backend = FakeDeviceBackend(trees: [screen("before"), screen("after")], advanceTreeOnInput: true)

        let first = label(in: try await backend.accessibilityTree(for: device))
        let again = label(in: try await backend.accessibilityTree(for: device))
        try await backend.perform(.tapAt(x: 10, y: 10), on: device)
        let after = label(in: try await backend.accessibilityTree(for: device))

        #expect([first, again, after] == ["before", "before", "after"])
        #expect(backend.session.calls == [.perform(.tapAt(x: 10, y: 10))])
        #expect(backend.openedSessions == [device])
    }

    @Test("a physical tap also advances the tree")
    func physicalTapAdvancesTree() async throws {
        let backend = FakeDeviceBackend(trees: [screen("before"), screen("after")], advanceTreeOnInput: true)

        try await backend.openInputSession(for: device).performPhysicalTap(at: (x: 5, y: 5), preDelay: nil, postDelay: nil)

        #expect(label(in: try await backend.accessibilityTree(for: device)) == "after")
    }

    @Test("a point read returns the deepest node there as the only root")
    func pointReadReturnsDeepestNode() async throws {
        let backend = FakeDeviceBackend(trees: [screen("one")])

        let hit = try await backend.accessibilityTree(for: device, point: UIPoint(x: 50, y: 120))
        let miss = try await backend.accessibilityTree(for: device, point: UIPoint(x: 500, y: 2000))

        #expect(hit.roots.map(\.id) == ["state"])
        #expect(miss.roots.isEmpty)
    }

    @Test("iOS coordinates without a tree cost a tree read; with one they do not")
    func iosCoordinatesCountTreeRead() async throws {
        let backend = FakeDeviceBackend(trees: [screen("one")])

        let points = try await backend.deviceCoordinates(for: [(x: 1, y: 2)], tree: nil, on: device)
        _ = try await backend.deviceCoordinates(for: [(x: 3, y: 4), (x: 5, y: 6)], tree: screen("one"), on: device)

        #expect(points.map(\.x) == [1] && points.map(\.y) == [2])
        #expect(backend.coordinateCalls.map(\.count) == [1, 2])
        #expect(backend.coordinateCalls.map(\.hadTree) == [false, true])
        #expect(backend.treeReads == 1)
    }

    @Test("Android coordinates never read a tree")
    func androidCoordinatesSkipTreeRead() async throws {
        let android = DeviceID(rawValue: "emulator-5556", platform: .android)
        let backend = FakeDeviceBackend(platform: .android, trees: [FakeUI.tree(platform: .android)])

        _ = try await backend.deviceCoordinates(for: [(x: 1, y: 2)], tree: nil, on: android)

        #expect(backend.treeReads == 0)
    }

    @Test("screenshots are served in order and an empty script fails")
    func screenshotsServedInOrder() async throws {
        let backend = FakeDeviceBackend(trees: [], screenshots: [Data([1]), Data([2])])
        let empty = FakeDeviceBackend(trees: [])

        let shots = [
            try await backend.screenshotPNG(for: device),
            try await backend.screenshotPNG(for: device),
            try await backend.screenshotPNG(for: device),
        ]

        #expect(shots == [Data([1]), Data([2]), Data([2])])
        #expect(backend.screenshotReads == 3)
        await #expect(throws: CLIError.self) { try await empty.screenshotPNG(for: device) }
    }
}
