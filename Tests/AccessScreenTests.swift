import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Device access screens")
struct AccessScreenTests {
    static let unicode = TerminalStyle(colours: false)
    static let ascii = TerminalStyle(colours: false, ascii: true)

    static let iPad = DeviceSummary(id: "00008140-000000000000ABCD", platform: .ios, state: "Booted", name: "Apple iPad Air", osVersion: nil, deviceType: "iPad Air", kind: .physical, connection: "usb")
    static let wireless = DeviceSummary(id: "00008130-000000000000DEF0", platform: .ios, state: "Booted", name: "Apple iPhone 17", osVersion: nil, deviceType: "iPhone 17", kind: .physical, connection: "network")
    static let phone = DeviceSummary(id: "R58M123ABC", platform: .android, state: "device", name: "Pixel 9", osVersion: nil, deviceType: nil, kind: .physical, connection: "usb")

    @Test("an answered question collapses to an aligned receipt line, and the summary before Touch ID is one bold line")
    func receiptLines() {
        let lines = ["Device", "Team", "App", "How long"].map { TerminalUI.receipt($0, "x", style: Self.unicode) }
        #expect(lines == ["✅ Device    x", "✅ Team      x", "✅ App       x", "✅ How long  x"])
        #expect(TerminalUI.receipt("Team", "Example Team", style: TerminalStyle(colours: true)) == "✅ \u{1B}[2mTeam    \u{1B}[0m  Example Team")
        #expect(AllowScreen.summary(Self.iPad, apps: [], lifetime: 43_200, team: "Example Team", width: 72, style: Self.unicode) == ["📲 iPad Air · any app · 12 hours · Example Team"])
        let narrow = AllowScreen.summary(Self.iPad, apps: [], lifetime: 43_200, team: "team ABCDE12345", width: 36, style: Self.unicode)
        #expect(narrow == ["📲 iPad Air · any app · 12 hours ·", "   team ABCDE12345"])
    }

    @Test("device rows lead with an emoji, then the name and only the ID's last four characters; a Wi-Fi device is dim and cannot be chosen")
    func deviceRows() {
        #expect(AllowScreen.deviceRow(Self.iPad, key: Self.iPad.id, style: Self.unicode) == MenuRow(.iPad, ["iPad Air", "…ABCD"]))
        #expect(AllowScreen.deviceRow(Self.phone, key: Self.phone.id, style: Self.ascii) == MenuRow(.android, ["Pixel 9", "...3ABC"]))
        #expect(AllowScreen.deviceRow(Self.wireless, key: Self.wireless.id, style: Self.unicode) == MenuRow(.iPhone, ["iPhone 17", AllowScreen.wifiOnly], enabled: false))
        let rows = [Self.iPad, Self.phone, Self.wireless].map { AllowScreen.deviceRow($0, key: $0.id, style: Self.unicode) }
        let drawn = TerminalUI.menu(AllowScreen.deviceQuestion, step: "1/4", rows: rows, selected: 0, controls: .init(rescan: true), style: Self.unicode)
        #expect(drawn == """
            1/4 Which phone or tablet? (↑↓, Enter, R rescan, Q quit)

              ▸ 📲  iPad Air   …ABCD
                🤖  Pixel 9    …3ABC
                📱  iPhone 17  Wi-Fi only, plug in a cable
            """)
        #expect(!drawn.contains(Self.iPad.id) && !drawn.contains(Self.phone.id))
        let coloured = TerminalUI.rows(rows, selected: 0, style: TerminalStyle(colours: true))
        #expect(coloured[0] == "  \u{1B}[32m▸ 📲  iPad Air \u{1B}[0m  \u{1B}[2m…ABCD\u{1B}[0m")
        #expect(coloured[2] == "    \u{1B}[2m📱  iPhone 17  Wi-Fi only, plug in a cable\u{1B}[0m")
    }

    @Test("with nothing to choose, the menu offers only rescan and quit, and warns in one yellow line")
    func emptyMenu() {
        let drawn = TerminalUI.menu(AllowScreen.deviceQuestion, step: "1/4", rows: [], selected: nil, controls: .init(choosing: false, rescan: true), warning: AllowScreen.noDevice, style: Self.unicode)
        #expect(drawn == "1/4 Which phone or tablet? (R rescan, Q quit)\n\n  ⚠️  \(AllowScreen.noDevice)")
        let coloured = TerminalUI.warning(AllowScreen.noDevice, width: 72, style: TerminalStyle(colours: true))
        #expect(coloured == ["\u{1B}[33m⚠️  \(AllowScreen.noDevice)\u{1B}[0m"])
    }

    @Test("the closing block names the full ID only in the commands, with the labels aligned and the commands never wrapped")
    func receipt() {
        let key = "00008140-000000000000ABCD"
        let lines = AllowScreen.allowed(name: "iPad Air", key: key, until: "until 22:14", apps: [], width: 72, style: Self.unicode)
        #expect(lines == [
            "✅ Allowed iPad Air until 22:14, any app.",
            "   Withdraw  offsider device-access remove --device \(key)",
            "   Next      offsider doctor --device \(key)",
        ])
        let narrow = AllowScreen.allowed(name: "iPad Air", key: key, until: "until 22:14", apps: [], width: 30, style: Self.unicode)
        #expect(narrow.filter { $0.contains(key) }.count == 2)
        #expect(narrow.last == "   Next      offsider doctor --device \(key)")
        let coloured = AllowScreen.allowed(name: "iPad Air", key: key, until: "until 22:14", apps: [], width: 72, style: TerminalStyle(colours: true))
        #expect(coloured[0] == "✅ \u{1B}[32m\u{1B}[1mAllowed iPad Air until 22:14, any app.\u{1B}[0m\u{1B}[0m")
        #expect(coloured[1] == "   \u{1B}[2mWithdraw\u{1B}[0m  \u{1B}[36moffsider device-access remove --device \(key)\u{1B}[0m")
        let ascii = AllowScreen.allowed(name: "iPad Air", key: key, until: "until 22:14", apps: [], width: 72, style: Self.ascii)
        #expect(ascii.first == "[OK] Allowed iPad Air until 22:14, any app.")
        #expect(ascii.last == "     Next      offsider doctor --device \(key)")
        let utc = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_060)
        #expect(AllowScreen.until(now.addingTimeInterval(7_200), now: now, timeZone: utc) == "until 16:14")
        #expect(AllowScreen.until(now.addingTimeInterval(7 * 86_400), now: now, timeZone: utc) == "until 28 Sep 14:14")
        #expect(AllowScreen.until(nil, now: now, timeZone: utc) == "until you remove it")
        #expect(AllowScreen.duration(3_600) == "1 hour")
        #expect(AllowScreen.duration(nil) == "until removed")
    }

    static let utc = TimeZone(identifier: "UTC")!

    static func policy(_ entries: [DeviceAllowance], managed: ManagedDevicePolicy = .none, sealIntact: Bool = true) -> PhysicalDevicePolicy {
        PhysicalDevicePolicy(managed: managed, list: DeviceAllowList(entries: entries), sealIntact: sealIntact)
    }

    @Test("the status screen lists each device agents may control with its apps, expiry and team, and hides expired ones")
    func statusScreenRows() {
        let iPad = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Apple Test iPad", added: PolicyFixtures.added, expires: PolicyFixtures.added.addingTimeInterval(3_600), apps: [], team: "ABCDE12345")
        let phone = DeviceAllowance(platform: .android, key: PolicyFixtures.serial, name: "Test Pixel", added: PolicyFixtures.added, expires: nil, apps: ["com.example.app"])
        let expired = DeviceAllowance(platform: .ios, key: "00008130-0000000000000DEF", name: "Old iPhone", added: PolicyFixtures.added, expires: PolicyFixtures.added, apps: [])
        let lines = AccessStatusScreen.lines(Self.policy([iPad, phone, expired]), now: PolicyFixtures.now, timeZone: Self.utc, width: 72, style: Self.unicode)
        #expect(lines.contains("  🔐  \(AccessStatusScreen.title)"))
        #expect(lines.contains("    📲  Test iPad   any app · until 15:13 · team ABCDE12345"))
        #expect(lines.contains("    🤖  Test Pixel  com.example.app · until removed"))
        #expect(!lines.joined().contains("Old iPhone"))
        #expect(Array(lines.suffix(2)) == ["  Allow     offsider device-access allow", "  Withdraw  offsider device-access remove --device <id>"])
        let single = AccessStatusScreen.lines(Self.policy([phone]), now: PolicyFixtures.now, timeZone: Self.utc, width: 72, style: Self.unicode)
        #expect(single.last == "  Withdraw  offsider device-access remove --device \(PolicyFixtures.serial)")
    }

    @Test("with nothing allowed the status screen says so and names the command that allows one")
    func statusScreenEmpty() {
        let lines = AccessStatusScreen.lines(Self.policy([]), now: PolicyFixtures.now, timeZone: Self.utc, width: 72, style: Self.unicode)
        #expect(Array(lines.suffix(2)) == ["⚠️  \(AccessStatusScreen.nothingAllowed)", "   Next  offsider device-access allow"])
        #expect(!lines.joined().contains("Withdraw"))
        let ascii = AccessStatusScreen.lines(Self.policy([]), now: PolicyFixtures.now, timeZone: Self.utc, width: 72, style: Self.ascii)
        #expect(ascii.last == "    Next  offsider device-access allow")
        #expect(ascii.allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) })
    }

    @Test("a managed policy that forbids devices shows one warning line, and the devices it blocks are not listed")
    func statusScreenManaged() {
        let off = AccessStatusScreen.lines(Self.policy([PolicyFixtures.entry()], managed: ManagedDevicePolicy(allowPhysicalDevices: false)), now: PolicyFixtures.now, timeZone: Self.utc, width: 72, style: Self.unicode)
        #expect(off.filter { $0.hasPrefix("⚠️") } == ["⚠️  \(AccessStatusScreen.managedBlocksAll)", "⚠️  \(AccessStatusScreen.nothingAllowed)"])
        let some = Self.policy(
            [PolicyFixtures.entry(), PolicyFixtures.entry(.android, key: PolicyFixtures.serial)], managed: ManagedDevicePolicy(allowedDeviceIDs: [PolicyFixtures.serial])
        )
        let lines = AccessStatusScreen.lines(some, now: PolicyFixtures.now, timeZone: Self.utc, width: 72, style: Self.unicode)
        #expect(lines.filter { $0.hasPrefix("⚠️") } == ["⚠️  \(AccessStatusScreen.managedBlocksSome)"])
        #expect(lines.filter { $0.contains("Test iPhone") }.count == 1)
        #expect(lines.contains { $0.hasPrefix("    🤖  Test iPhone") })
    }
}
