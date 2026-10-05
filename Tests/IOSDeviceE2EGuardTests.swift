import Foundation
import Testing

@Suite("iOS device E2E guard")
struct IOSDeviceE2EGuardTests {
    static let ipad = "00008132-0000AAAA1111BBBB"
    static let phone = "00008130-0000CCCC2222DDDD"
    static let simulator = "E2E00000-0000-4000-8000-000000000001"

    /// One Xcode 27 row per device, in `devicectl list devices --json-output -` form.
    static func row(udid: String, reality: String, platform: String, deviceType: String = "iPad") -> String {
        """
        {"identifier": "\(UUID().uuidString)", "properties": {"hardware": {"udid": "\(udid)", "reality": "\(reality)", "platform": "\(platform)", "deviceType": "\(deviceType)"}}}
        """
    }

    static func listing(_ rows: [String]) -> Data {
        Data((#"{"info": {"outcome": "success"}, "result": {"devices": ["# + rows.joined(separator: ",") + "]}}").utf8)
    }

    static let attached = listing([
        row(udid: ipad, reality: "physical", platform: "iOS"),
        row(udid: phone, reality: "physical", platform: "iOS", deviceType: "iPhone"),
        row(udid: simulator, reality: "simulated", platform: "iOS", deviceType: "iPhone"),
        row(udid: "00008301-0000EEEE3333FFFF", reality: "physical", platform: "watchOS", deviceType: "appleWatch"),
    ])

    private func refusal(_ result: Result<String, IOSDeviceE2EError>) -> String? {
        if case .failure(let error) = result { return error.description }
        return nil
    }

    @Test("the named UDID is accepted when devicectl lists it as a physical iOS device")
    func exactMatch() throws {
        #expect(try IOSDeviceE2EGuard.verdict(requested: Self.ipad, listing: Self.attached).get() == Self.ipad)
    }

    @Test("a UDID devicectl does not list is refused, even with other phones attached")
    func differentUDIDRefused() {
        let message = refusal(IOSDeviceE2EGuard.verdict(requested: "00008132-0000999988887777", listing: Self.attached))
        #expect(message?.contains("does not list it") == true)
    }

    @Test("a prefix or a different case of an attached UDID is not a match")
    func noLooseMatch() {
        #expect(refusal(IOSDeviceE2EGuard.verdict(requested: Self.ipad.lowercased(), listing: Self.attached)) != nil)
        #expect(refusal(IOSDeviceE2EGuard.verdict(requested: String(Self.ipad.dropLast()), listing: Self.attached)) != nil)
    }

    @Test("a simulator is refused before any devicectl call, and again if a listing marks a UDID-shaped row simulated")
    func simulatorRefused() {
        #expect(refusal(IOSDeviceE2EGuard.verdict(requested: Self.simulator, listing: Self.attached))?.contains("never a simulator") == true)
        let simulated = Self.listing([Self.row(udid: Self.ipad, reality: "simulated", platform: "iOS")])
        #expect(refusal(IOSDeviceE2EGuard.verdict(requested: Self.ipad, listing: simulated))?.contains("simulated") == true)
    }

    @Test("a physical device on another platform is refused")
    func watchRefused() {
        #expect(refusal(IOSDeviceE2EGuard.verdict(requested: "00008301-0000EEEE3333FFFF", listing: Self.attached))?.contains("watchOS") == true)
    }

    @Test("a missing or blank OFFSIDER_IOS_DEVICE is refused", arguments: [nil, "", "  "] as [String?])
    func missingRefused(value: String?) {
        #expect(refusal(IOSDeviceE2EGuard.verdict(requested: value, listing: Self.attached))?.contains("OFFSIDER_IOS_DEVICE must name") == true)
    }

    @Test("an Xcode 26 listing with only hardwareProperties is read too")
    func olderShape() throws {
        let older = Data(#"{"result": {"devices": [{"hardwareProperties": {"udid": "00008132-0000AAAA1111BBBB", "reality": "physical", "platform": "iOS"}}]}}"#.utf8)
        #expect(try IOSDeviceE2EGuard.verdict(requested: Self.ipad, listing: older).get() == Self.ipad)
    }

    @Test("the team must be a 10-character team ID")
    func team() {
        #expect((try? IOSDeviceE2EGuard.team("ABCDE12345").get()) == "ABCDE12345")
        for bad in [nil, "", "ABCD", "abcde12345"] as [String?] {
            #expect((try? IOSDeviceE2EGuard.team(bad).get()) == nil, "accepted \(bad ?? "nil")")
        }
    }

    @Test("a dark screen skips input suites; a lit one does not")
    func asleep() {
        let lock = Data(#"{"result": {"passcodeRequired": true, "unlockedSinceBoot": true}}"#.utf8)
        let off = Data(#"{"result": {"backlightState": "off", "displays": []}}"#.utf8)
        let on = Data(#"{"result": {"backlightState": "on", "displays": []}}"#.utf8)
        #expect(IOSDeviceE2EGuard.asleepReason(displays: off, lockState: lock, deviceType: "iPad")?.hasPrefix("skipped: iPad asleep or locked") == true)
        #expect(IOSDeviceE2EGuard.asleepReason(displays: Data("{}".utf8), lockState: lock, deviceType: "iPad") != nil)
        #expect(IOSDeviceE2EGuard.asleepReason(displays: on, lockState: lock, deviceType: "iPad") == nil)
    }

    @Test("signing and lock failures are told apart from other install failures")
    func signingOrLock() {
        #expect(IOSDeviceE2EGuard.isSigningOrLock("Failed to install embedded profile: 0xe8008012 (This provisioning profile cannot be installed on this device.)"))
        #expect(IOSDeviceE2EGuard.isSigningOrLock("error: No Accounts: Add a new account in Accounts settings."))
        #expect(!IOSDeviceE2EGuard.isSigningOrLock("error: cannot find 'ContentView' in scope"))
    }
}
