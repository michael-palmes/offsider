import Foundation
import OffsiderCore
import Testing

@Suite("Status bar")
struct StatusBarTests {
    @Test("the default override is 9:41, full battery not charging, full signal")
    func defaultOverride() {
        #expect(StatusBarOverride().iosOverrideArguments(udid: "SIM") == [
            "simctl", "status_bar", "SIM", "override", "--time", "9:41", "--dataNetwork", "wifi",
            "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
            "--operatorName", "", "--batteryState", "discharging", "--batteryLevel", "100",
        ])
    }

    @Test("radios turned off use the failed and not-supported modes")
    func radiosOff() {
        var override = StatusBarOverride()
        override.wifiBars = nil
        override.cellularBars = nil
        override.dataNetwork = .none
        let arguments = override.iosOverrideArguments(udid: "SIM")
        #expect(arguments.joined(separator: " ").contains("--dataNetwork hide --wifiMode failed --wifiBars 0 --cellularMode notSupported --operatorName"))
        #expect(override.androidEnterScript.contains("network -e wifi hide"))
        #expect(override.androidEnterScript.contains("network -e mobile hide"))
    }

    @Test("Wi-Fi bars map onto Android levels", arguments: [(0, 0), (1, 1), (2, 3), (3, 4)])
    func wifiLevels(bars: Int, level: Int) {
        #expect(StatusBarOverride.androidWifiLevel(bars: bars) == level)
    }

    @Test("the Android override is one script that reads the earlier setting first, then enters demo mode")
    func androidEnter() {
        var override = StatusBarOverride()
        override.time = "10:05"
        override.charging = true
        let script = override.androidEnterScript
        #expect(script.hasPrefix("settings get global sysui_demo_allowed; settings put global sysui_demo_allowed 1 && am broadcast -a com.android.systemui.demo -e command enter > /dev/null"))
        #expect(script.contains("-e command clock -e hhmm 1005 > /dev/null"))
        #expect(script.contains("-e command battery -e level 100 -e plugged true > /dev/null"))
        #expect(script.contains("-e command network -e wifi show -e level 4 -e fully true"))
        #expect(script.contains("-e command network -e mobile show -e datatype lte -e level 4 -e fully true"))
        #expect(script.hasSuffix("-e command notifications -e visible false > /dev/null"))
        var early = StatusBarOverride()
        early.time = "9:41"
        #expect(early.androidEnterScript.contains("hhmm 0941"))
    }

    @Test("clear exits demo mode and deletes the allow setting")
    func androidClear() {
        #expect(StatusBarOverride.androidClearScript == "am broadcast -a com.android.systemui.demo -e command exit > /dev/null; settings delete global sysui_demo_allowed > /dev/null")
    }

    @Test("the demo-allowed setting reads as allowed, not allowed or never set", arguments: [("1\n", true), ("0", false), ("null\n", nil)] as [(String, Bool?)])
    func demoAllowed(output: String, expected: Bool?) {
        #expect(StatusBarOverride.parseDemoAllowed(output) == expected)
    }

    @Test("the iOS override list parses into its fields, and an empty list into none")
    func iosList() {
        let output = """
        Current Status Bar Overrides:
        =============================
        Time: 9:41 
        DataNetworkType: 11
        WiFi Mode: 3, WiFi Bars: 3
        Cell Mode: 3, Cell Bars: 4
        Operator Name: 
        Battery State: 0, Battery Level: 100, Not Charging: 0
        """
        let pairs = Dictionary(uniqueKeysWithValues: StatusBarOverride.parseIOSList(output).map { ($0.key, $0.value) })
        #expect(pairs["Time"] == "9:41")
        #expect(pairs["WiFi Bars"] == "3")
        #expect(pairs["Cell Bars"] == "4")
        #expect(pairs["Battery Level"] == "100")
        #expect(pairs["Operator Name"] == "")
        #expect(StatusBarOverride.parseIOSList("Current Status Bar Overrides:\n=============================\n").isEmpty)
    }

    @Test("times and bars are checked", arguments: ["25:00", "9:5", "nine", "9:61"])
    func badTime(text: String) {
        #expect(throws: DeviceSettingsError.self) { try StatusBarOverride.parseTime(text) }
    }

    @Test("times normalise and bars accept off")
    func goodValues() throws {
        #expect(try StatusBarOverride.parseTime("09:41") == "9:41")
        #expect(try StatusBarOverride.parseBars("off", option: "--wifi", maximum: 3) == nil)
        #expect(try StatusBarOverride.parseBars("2", option: "--wifi", maximum: 3) == 2)
        #expect(throws: DeviceSettingsError.self) { try StatusBarOverride.parseBars("4", option: "--wifi", maximum: 3) }
    }
}
