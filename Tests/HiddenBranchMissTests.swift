import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// Android leaves a view it marks not visible out of the tree and names it in `hiddenBranches`, such as a row wholly under three-button navigation.
@Suite("A selector that matches only a hidden branch")
@MainActor
struct HiddenBranchMissTests {
    static let device = CoverAndVerifyTests.android

    /// The playground's long list with row 12 under a 48 dp navigation bar at the bottom of a 412 x 915 dp screen.
    static func tree(hidden: UITreeContext.HiddenBranch) -> UITree {
        var tree = FakeUI.tree(platform: .android, width: 412, height: 915, [
            FakeUI.node(.button, id: "row-1", label: "Row 1", frame: FakeUI.frame(0, 100, 412, 56), platform: .android),
            FakeUI.node(.button, id: "row-2", label: "Row 2", frame: FakeUI.frame(0, 156, 412, 56), platform: .android),
        ])
        tree.windows = [
            UIWindowInfo(id: 1, kind: "application", layer: 1, title: "Playground", active: true, focused: true, package: "com.mpalmes.offsider.playground.rn", bounds: FakeUI.frame(0, 0, 412, 915)),
            UIWindowInfo(id: 2, kind: "system", layer: 2, title: "Navigation bar", active: false, focused: false, package: "com.android.systemui", bounds: FakeUI.frame(0, 867, 412, 48)),
        ]
        tree.namedHiddenBranches = [hidden]
        return tree
    }

    static let underBar = UITreeContext.HiddenBranch(id: "row-12", label: "Row 12", className: "android.view.ViewGroup", frame: FakeUI.frame(0, 870, 412, 56))

    static func miss(_ arguments: [String], hidden: UITreeContext.HiddenBranch = underBar) async -> (any Error)? {
        let backend = FakeDeviceBackend(platform: .android, trees: [tree(hidden: hidden)])
        do {
            try await CoverAndVerifyTests.tap(arguments, on: backend, device: device)
        } catch {
            #expect(backend.session.calls.isEmpty)
            return error
        }
        Issue.record("the tap went through")
        return nil
    }

    @Test("an id or label Android lists only as hidden under the navigation bar says so and to scroll it up, not Did you mean", arguments: [
        ["--id", "row-12"], ["--label", "Row 12"], ["--label-contains", "Row 12"],
    ])
    func underNavigationBar(arguments: [String]) async throws {
        let error = try #require(await Self.miss(arguments + ["--wait-timeout", "0"]) as? HiddenBranchMiss)
        #expect(error.reason == .selectorNotFound)
        #expect(error.userFacingDescription.hasPrefix("No accessibility element matched"))
        #expect(error.userFacingDescription.contains("it is under the navigation bar at (0, 870) 412x56, so Android marks it hidden. Nothing was sent. Scroll it up above the bar, then retry."))
        #expect(!error.userFacingDescription.contains("Did you mean"))
    }

    @Test("a hidden branch away from the bars is named as hidden, with no bar blamed")
    func hiddenElsewhere() async throws {
        let behind = UITreeContext.HiddenBranch(id: "row-12", label: nil, className: nil, frame: FakeUI.frame(0, 300, 412, 56))
        let error = try #require(await Self.miss(["--id", "row-12", "--wait-timeout", "0"], hidden: behind) as? HiddenBranchMiss)
        #expect(error.userFacingDescription.hasPrefix("No accessibility element matched --id 'row-12' on screen: Android lists it as hidden at (0, 300) 412x56, as it does a view another covers"))
        #expect(!error.userFacingDescription.contains("navigation bar"))
    }

    @Test("a hidden branch wholly off the screen, as on a parked sheet, is named as off the screen")
    func hiddenOffScreen() async throws {
        let parked = UITreeContext.HiddenBranch(id: "row-12", label: nil, className: nil, frame: FakeUI.frame(140, 10_643, 128, 0))
        let error = try #require(await Self.miss(["--id", "row-12", "--wait-timeout", "0"], hidden: parked) as? HiddenBranchMiss)
        #expect(error.userFacingDescription.contains("off the screen, as on a sheet parked out of view"), "\(error.userFacingDescription)")
        #expect(!error.userFacingDescription.contains("navigation bar"))
    }

    @Test("a selector no hidden branch matches keeps the usual miss")
    func otherMiss() async throws {
        let error = await Self.miss(["--id", "row-99", "--wait-timeout", "0"])
        #expect(error is ElementResolutionError)
    }
}
