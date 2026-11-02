import Foundation
@testable import OffsiderAndroid
import OffsiderCore
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

    /// The Android 8 to 10 path, run by the device's own shell, with `cmd notification` made to fail so the script takes it.
    static func dumpPath(_ package: String) async throws -> String {
        try await AndroidE2E.shell("cmd() { return 255; }\n" + AndroidNotifications.script(package: package))
    }

    @Test("the dump path in the device's own shell keeps a line ending in : in the app's text, hides it from another app and tells a mistyped package")
    func dumpPathOnTheDevice() async throws {
        guard try await AndroidE2E.apiLevel() >= 29 else { return }
        let tag = "offsider-dump-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await AndroidE2E.shell("cmd notification post -S bigtext -t 'Dump (\(tag))' \(tag) $'Ready (today)\\nShopping list:\\nTotal 5.00'")
        var found: PostedNotification?
        for _ in 0..<20 where found == nil {
            let output = try await Self.dumpPath(Self.shell)
            found = AndroidNotifications.parse(output, package: Self.shell)?.notifications.first { $0.tag == tag }
            if found == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        #expect(found?.text == "Ready (today)\nShopping list:\nTotal 5.00")

        let other = try await Self.dumpPath(AndroidE2E.package)
        #expect(!other.contains(tag) && !other.contains("Shopping list"))
        #expect(AndroidNotifications.parse(other, package: AndroidE2E.package)?.notifications.allSatisfy { $0.tag != tag } == true)
        #expect(!AndroidNotifications.notInstalled(other))

        #expect(AndroidNotifications.notInstalled(try await Self.dumpPath("com.exmaple.absent")))
    }

    @Test("a mistyped package exits 1 with app_not_installed at once, not at the end of a --wait")
    func mistypedPackage() async throws {
        let started = ContinuousClock.now
        let result = try await AndroidE2E.offsider("notifications --app com.exmaple.absent --wait 'x' --timeout 30 --json")
        #expect(result.exitCode == 1)
        #expect((result.stdout + result.stderr).contains("app_not_installed"))
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test("a wait for text no notification holds exits 5 at its timeout")
    func waitTimesOut() async throws {
        let result = try await AndroidE2E.offsider("notifications --app \(AndroidE2E.package) --wait 'never posted text' --timeout 2")
        #expect(result.exitCode == 5)
        #expect(result.stderr.contains("within 2 s"))
    }
}
