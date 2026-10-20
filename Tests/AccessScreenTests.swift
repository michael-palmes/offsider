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
            "   Withdraw  offsider devices remove --device \(key)",
            "   Next      offsider doctor --device \(key)",
        ])
        let narrow = AllowScreen.allowed(name: "iPad Air", key: key, until: "until 22:14", apps: [], width: 30, style: Self.unicode)
        #expect(narrow.filter { $0.contains(key) }.count == 2)
        #expect(narrow.last == "   Next      offsider doctor --device \(key)")
        let coloured = AllowScreen.allowed(name: "iPad Air", key: key, until: "until 22:14", apps: [], width: 72, style: TerminalStyle(colours: true))
        #expect(coloured[0] == "✅ \u{1B}[32m\u{1B}[1mAllowed iPad Air until 22:14, any app.\u{1B}[0m\u{1B}[0m")
        #expect(coloured[1] == "   \u{1B}[2mWithdraw\u{1B}[0m  \u{1B}[36moffsider devices remove --device \(key)\u{1B}[0m")
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

    /// The status page as a person reads it at 80 columns: stdout, then stderr.
    static func drawn(_ policy: PhysicalDevicePolicy, style: TerminalStyle = unicode) -> (out: String, err: String) {
        let capture = ConsoleCapture()
        capture.console(out: .person(style: style), err: .person(style: style)).show(AccessStatusScreen.page(policy, now: PolicyFixtures.now, timeZone: utc, agent: "agent text\n"))
        return (capture.out, capture.err)
    }

    @Test("the status screen counts the devices agents may control, a row each with apps, expiry and team, hides expired ones and ends with the commands")
    func statusScreenRows() {
        let iPad = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Apple Test iPad", added: PolicyFixtures.added, expires: PolicyFixtures.added.addingTimeInterval(3_600), apps: [], team: "ABCDE12345")
        let phone = DeviceAllowance(platform: .android, key: PolicyFixtures.serial, name: "Test Pixel", added: PolicyFixtures.added, expires: nil, apps: ["com.example.app"])
        let expired = DeviceAllowance(platform: .ios, key: "00008130-0000000000000DEF", name: "Old iPhone", added: PolicyFixtures.added, expires: PolicyFixtures.added, apps: [])
        let (out, err) = Self.drawn(Self.policy([iPad, phone, expired]))
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("🔐  \(AccessStatusScreen.title)") == true && lines.first?.hasSuffix("2 allowed") == true)
        #expect(lines.contains("  ● Test iPad   any app          until 15:13    team ABCDE12345"))
        #expect(lines.contains("  ● Test Pixel  com.example.app  until removed"))
        #expect(!out.contains("Old iPhone") && !out.contains("agent text"))
        #expect(lines.suffix(2).map { $0.trimmingCharacters(in: .whitespaces) } == [
            "offsider devices add     add another", "offsider devices remove  withdraw one",
        ])
        #expect(err.isEmpty)
        let single = Self.drawn(Self.policy([phone])).out
        #expect(single.hasSuffix("  offsider devices remove --device \(PolicyFixtures.serial)  withdraw it\n"))
    }

    @Test("with nothing allowed the status screen says so and names the command that allows one")
    func statusScreenEmpty() {
        let (out, err) = Self.drawn(Self.policy([]))
        #expect(out.hasPrefix("🔐  \(AccessStatusScreen.title)") && out.contains("none allowed") && out.contains(AccessStatusScreen.nothingAllowed))
        #expect(err == "\nNext  offsider devices add\n")
        #expect(!out.contains("withdraw"))
        let ascii = Self.drawn(Self.policy([]), style: Self.ascii)
        let text = ascii.out + ascii.err
        #expect(text.unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test("a managed policy that forbids devices is one warning, and the devices it blocks are not listed")
    func statusScreenManaged() {
        let off = Self.drawn(Self.policy([PolicyFixtures.entry()], managed: ManagedDevicePolicy(allowPhysicalDevices: false)))
        #expect(off.err.split(separator: "\n").filter { $0.hasPrefix("⚠️") } == ["⚠️  \(AccessStatusScreen.managedBlocksAll)"])
        #expect(!off.err.contains("Try"))
        #expect(off.out.contains(AccessStatusScreen.nothingAllowed))
        let some = Self.policy(
            [PolicyFixtures.entry(), PolicyFixtures.entry(.android, key: PolicyFixtures.serial)], managed: ManagedDevicePolicy(allowedDeviceIDs: [PolicyFixtures.serial])
        )
        let (out, err) = Self.drawn(some)
        #expect(err.split(separator: "\n").filter { $0.hasPrefix("⚠️") } == ["⚠️  \(AccessStatusScreen.managedBlocksSome)"])
        #expect(out.components(separatedBy: "Test iPhone").count == 2)
        #expect(out.contains("  ● Test iPhone  any app  until 15:13"))
    }

    @Test("an agent reads the status text it always did, and no notice")
    func statusScreenForAnAgent() {
        let capture = ConsoleCapture()
        let page = AccessStatusScreen.page(Self.policy([PolicyFixtures.entry()]), now: PolicyFixtures.now, timeZone: Self.utc, agent: "agent text\n")
        capture.console(out: .agent, err: .agent).show(Page(page.blocks))
        #expect(capture.out == "agent text\n")
        #expect(capture.err.isEmpty)
    }
}
