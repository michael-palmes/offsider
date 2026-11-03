import Foundation
import Testing

/// Sign-in on the debug playground, where Expo's Tools button floats over every screen in a full-screen window of its own.
@Suite("React Native debug login", .serialized, .enabled(if: isRNDebugE2EEnabled && RNPlatform.anyEnabled), RNDebugSession(), SavedUsersScope())
struct ReactNativeDebugLoginTests {
    @Test("login signs in first time with the Tools button left on, as a fresh dev build has it", arguments: RNPlatform.enabled)
    func signsInUnderToolsButton(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)
        _ = try await app.offsider("rn logbox dismiss")
        let nodes = DescribeUITree.nodes(in: try await app.tree())
        let toolsButton = nodes.contains { node in
            node["id"] as? String == "gearshape.fill" || (node["label"] as? String == "Tools" && node["role"] as? String == "image")
        }
        try #require(toolsButton, "the Tools button is off, so this run proves nothing")

        let report = try await RNLogin.signIn(app, "--where role=admin")

        #expect(report["submitted"] as? Bool == true)
        #expect(report["identity"] as? String == "filled")
        #expect(report["password"] as? String == "filled")
        try await RNLogin.expectSignedIn(app, as: RNLoginUsers.admin, signIns: 1)
        try await RNLogin.signOutInApp(app)
        try await RNLogin.signedOut(app)
    }
}
