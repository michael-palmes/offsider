import Foundation
import Testing

@Suite("Android notifications E2E", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidNotificationsE2ETests {
    static let shell = "com.android.shell"

    static func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("a notification posted while waiting is found, with its one-time code hidden and only its own app's records listed")
    func waitFindsPostedNotification() async throws {
        guard try await AndroidE2E.apiLevel() >= 29 else { return }
        let tag = "offsider-e2e-\(UUID().uuidString.prefix(8).lowercased())"
        async let found = AndroidE2E.offsider("notifications --app \(Self.shell) --wait 'Offsider E2E \(tag)' --timeout 30 --json")
        try await Task.sleep(for: .seconds(2))
        _ = try await AndroidE2E.shell("cmd notification post -t 'Offsider E2E \(tag)' \(tag) 'Your verification code is 482915'")
        let result = try await found
        #expect(result.exitCode == 0, "\(result.stderr)")
        let object = try Self.json(result.stdout)
        let notifications = try #require(object["notifications"] as? [[String: Any]])
        #expect(notifications.count == 1)
        #expect(notifications.first?["tag"] as? String == tag)
        #expect((notifications.first?["text"] as? String)?.contains("482915") == false)
        #expect(object["redacted"] as? Int == 1)

        let listed = try Self.json(try await AndroidE2E.run("notifications --app \(Self.shell) --json").stdout)
        let keys = (listed["notifications"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
        #expect(keys.contains { $0.contains("|\(tag)|") })
        #expect(keys.allSatisfy { $0.split(separator: "|").dropFirst().first == Substring(Self.shell) })
    }

    @Test("with --new a notification already showing does not pass the wait, and one posted during it does")
    func newIgnoresEarlier() async throws {
        guard try await AndroidE2E.apiLevel() >= 29 else { return }
        let tag = "offsider-new-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await AndroidE2E.shell("cmd notification post -t 'Offsider new \(tag)' \(tag)-old 'earlier'")
        try await AndroidE2E.run("notifications --app \(Self.shell) --wait 'Offsider new \(tag)' --timeout 10")
        let stale = try await AndroidE2E.offsider("notifications --app \(Self.shell) --wait 'Offsider new \(tag)' --new --timeout 3")
        #expect(stale.exitCode == 5)

        async let found = AndroidE2E.offsider("notifications --app \(Self.shell) --wait 'Offsider new \(tag)' --new --timeout 30 --json")
        try await Task.sleep(for: .seconds(2))
        _ = try await AndroidE2E.shell("cmd notification post -t 'Offsider new \(tag)' \(tag)-fresh 'later'")
        let result = try await found
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect((try Self.json(result.stdout)["notifications"] as? [[String: Any]])?.first?["tag"] as? String == "\(tag)-fresh")
    }

    @Test("a wait for text no notification holds exits 5 at its timeout")
    func waitTimesOut() async throws {
        let result = try await AndroidE2E.offsider("notifications --app \(AndroidE2E.package) --wait 'never posted text' --timeout 2")
        #expect(result.exitCode == 5)
        #expect(result.stderr.contains("within 2 s"))
    }
}
