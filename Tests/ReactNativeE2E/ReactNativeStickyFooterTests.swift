import Foundation
import Testing

@Suite("React Native sticky footer", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeStickyFooterTests {
    static let route = "sticky-footer-test"
    static let untouched = "Sticky Footer Pressed: None"

    static func frame(of id: String, in tree: [String: Any]) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let frame = DescribeUITree.node(id: id, in: tree)?["frame"] as? [String: Double],
              let x = frame["x"], let y = frame["y"], let width = frame["width"], let height = frame["height"] else { return nil }
        return (x, y, width, height)
    }

    static let rowIDs = (1...30).map { "sticky-footer-test-row-\($0)" }

    @Test("a row below the scroll view's fold, under the pinned footer, is refused as off screen and nothing is pressed", arguments: RNPlatform.enabled)
    func rowBelowFoldRefused(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open(Self.route)
        let tree = try await app.tree()
        let scroll = try #require(Self.frame(of: "sticky-footer-test-scroll-view", in: tree))
        let screen = try await app.screenSize()
        let fold = scroll.y + scroll.height
        let hidden = Self.rowIDs.first { id in
            Self.frame(of: id, in: tree).map { $0.y >= fold && $0.y < screen.height } ?? false
        }
        guard let hidden else {
            #expect(platform == .android, "iOS lists the rows its scroll view clips; none was found below \(fold)")
            return
        }

        let result = try await app.offsider("tap --id \(hidden) --fail-if-covered")

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("below the fold of its scroll view; scroll first"), "\(result.stderr)")
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "sticky-footer-test-pressed") == Self.untouched)
    }

    @Test("a switch under the vertical scroll indicator taps with --fail-if-covered", arguments: RNPlatform.enabled)
    func switchUnderIndicatorTaps(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open(Self.route)
        if platform == .ios {
            let centre = try await app.centre(of: "sticky-footer-test-switch-1")
            _ = try await app.waitForNode { node in
                guard node["role"] as? String == "slider", let frame = node["frame"] as? [String: Double],
                      let x = frame["x"], let y = frame["y"], let width = frame["width"], let height = frame["height"] else { return false }
                return Double(centre.x) >= x && Double(centre.x) < x + width && Double(centre.y) >= y && Double(centre.y) < y + height
            }
        }

        let result = try await app.run("tap --id sticky-footer-test-switch-1 --fail-if-covered")

        #expect(!result.stderr.contains("covered"), "\(result.stderr)")
        _ = try await app.waitForNode { node in
            node["id"] as? String == "sticky-footer-test-switch-1" && (node["state"] as? [String: Any])?["checked"] as? Bool == true
        }
    }

    @Test("a row under the floating footer is refused as covered and nothing is pressed", arguments: RNPlatform.enabled)
    func rowUnderFloatingFooterRefused(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open(Self.route)
        try await app.run("tap --id sticky-footer-test-toggle-floating")
        _ = try await app.waitForNode { $0["label"] as? String == "Pin Footer" }
        let tree = try await app.tree()
        let footer = try #require(Self.frame(of: "sticky-footer-test-footer", in: tree))
        let centre = (x: footer.x + footer.width / 2, y: footer.y + footer.height / 2)
        let row = try #require(Self.rowIDs.first { id in
            Self.frame(of: id, in: tree).map { centre.y >= $0.y && centre.y < $0.y + $0.height } ?? false
        }, "no row lies under the floating footer")

        let result = try await app.offsider("tap --id \(row) --fail-if-covered")

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("covered by"), "\(result.stderr)")
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "sticky-footer-test-pressed") == Self.untouched)
    }
}
