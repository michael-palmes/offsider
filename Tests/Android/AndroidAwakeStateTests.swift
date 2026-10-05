import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// Replies in order, holding the last.
final class ScriptedOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]

    init(_ outputs: [String]) {
        self.outputs = outputs
    }

    func next() -> String {
        lock.withLock { outputs.count > 1 ? outputs.removeFirst() : outputs[0] }
    }
}

@Suite("Android awake state")
@MainActor
struct AndroidAwakeStateTests {
    static let device = AndroidBackendTests.device
    nonisolated static let shellPrefix = "shell,v2,raw:"

    /// A moto g57 on Android 16, awake and unlocked, as the read script prints it.
    nonisolated static let motoAwake = """
      mWakefulness=Awake
      mIsPowered=true
      mPlugType=1
      mScreenOffTimeoutSetting=1800000
      mMaximumScreenOffTimeoutFromDeviceAdmin=9223372036854775807 (enforced=false)
      mStayOnWhilePluggedInSetting=0
      mIsPowered=true
          showing=false
          occluded=false
          secure=true
        CredentialType: PIN

    """

    nonisolated static func state(_ wakefulness: String = "Awake", showing: Bool = false, secure: Bool = true, stayOn: Int = 0) -> String {
        motoAwake
            .replacingOccurrences(of: "mWakefulness=Awake", with: "mWakefulness=\(wakefulness)")
            .replacingOccurrences(of: "showing=false", with: "showing=\(showing)")
            .replacingOccurrences(of: "secure=true", with: "secure=\(secure)")
            .replacingOccurrences(of: "mStayOnWhilePluggedInSetting=0", with: "mStayOnWhilePluggedInSetting=\(stayOn)")
    }

    /// The lock screen with System UI's PIN field focused, or `package`'s own focused password field.
    nonisolated static func dump(package: String = "com.android.systemui", focused: Bool = true) -> String {
        """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="\(package):id/keyguard_security_container" class="android.widget.FrameLayout" package="\(package)" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][1080,2424]" hint=""><node index="0" text="" resource-id="\(package):id/pinEntry" class="android.widget.EditText" package="\(package)" content-desc="PIN area" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="\(focused)" scrollable="false" long-clickable="false" password="true" selected="false" bounds="[184,679][895,815]" hint="" /></node></hierarchy>
        """
    }

    static func server(states: ScriptedOutputs, dump: String = dump(), reply: @escaping @Sendable (String) -> FakeAdbServer.Reply? = { _ in nil }) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in
                let command = service.hasPrefix(shellPrefix) ? String(service.dropFirst(shellPrefix.count)) : service
                if let reply = reply(command) { return reply }
                if command == AndroidAwakeState.readScript { return FakeAdbServer.shell(stdout: states.next()) }
                if command.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
                if command.contains("uiautomator dump") { return FakeAdbServer.shell(stdout: dump) }
                return FakeAdbServer.shell()
            }
        ))
    }

    static func backend(_ server: FakeAdbServer) throws -> AndroidBackend {
        let host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"], adb: server)
        return AndroidBackend(host: host) { _, _ in }
    }

    static func shellCommands(_ server: FakeAdbServer) -> [String] {
        server.services.filter { $0.hasPrefix(shellPrefix) }.map { String($0.dropFirst(shellPrefix.count)) }
    }

    // MARK: Parsing

    @Test("an awake moto reads on and unlocked, charging over AC, with a PIN set and the first repeated key winning")
    func parseAwake() throws {
        let reading = try #require(AndroidAwakeState.parse(Self.motoAwake))
        #expect(reading == AwakeReading(screen: .on, lockScreen: .hidden, credential: "pin", stayAwake: [], charging: [.ac], screenTimeoutMilliseconds: 1_800_000))
    }

    @Test("the maker the read script echoes first names the phone, and an empty one is nil")
    func parseMaker() {
        #expect(AndroidAwakeState.parse("maker=motorola\n" + Self.motoAwake)?.maker == "motorola")
        #expect(AndroidAwakeState.parse("maker=\n" + Self.motoAwake)?.maker == nil)
        #expect(AndroidAwakeState.readScript.hasPrefix("echo maker=$(getprop ro.product.manufacturer); "))
    }

    @Test("asleep with the keyguard showing reads off behind a secure lock screen")
    func parseAsleep() throws {
        let reading = try #require(AndroidAwakeState.parse(Self.state("Asleep", showing: true)))
        #expect(reading.screen == .off)
        #expect(reading.lockScreen == .secure)
        #expect(!reading.isUsable)
    }

    @Test("an app shown over the lock screen counts as hidden, and a lock screen with no credential is a swipe")
    func parseOccludedAndSwipe() throws {
        let occluded = Self.state(showing: true).replacingOccurrences(of: "occluded=false", with: "occluded=true")
        #expect(AndroidAwakeState.parse(occluded)?.lockScreen == .hidden)
        #expect(AndroidAwakeState.parse(Self.state(showing: true, secure: false))?.lockScreen == .swipe)
    }

    @Test("Android 11 names a password credential in mixed case, and a device policy cap is read")
    func parsePixel() throws {
        let pixel = Self.motoAwake
            .replacingOccurrences(of: "CredentialType: PIN", with: "CredentialType: Password")
            .replacingOccurrences(of: "(enforced=false)", with: "(enforced=true)")
        let reading = try #require(AndroidAwakeState.parse(pixel))
        #expect(reading.credential == "password")
        #expect(reading.timeoutCappedByPolicy)
    }

    @Test("states map from mWakefulness, and output without it or the keyguard is unreadable")
    func parseStates() {
        #expect(["Awake", "Asleep", "Dozing", "Dreaming"].compactMap { AndroidAwakeState.parse(Self.state($0))?.screen } == [.on, .off, .dozing, .dreaming])
        #expect(AndroidAwakeState.parse("  mWakefulness=Awake\n") == nil)
        #expect(AndroidAwakeState.parse("      showing=false\n") == nil)
        #expect(AndroidAwakeState.parse(Self.state("Hibernating")) == nil)
    }

    @Test("a set reads the reading before and the value written back after the marker")
    func parseSet() throws {
        let (before, after) = try #require(AndroidAwakeState.parseSet(Self.motoAwake + AndroidAwakeState.afterMarker + "\n15\n"))
        #expect(before.stayAwake.isEmpty)
        #expect(after == [.ac, .usb, .wireless, .dock])
        #expect(AndroidAwakeState.parseSet(Self.motoAwake) == nil)
    }

    // MARK: Scripts

    @Test("wake sends the wake key only for a dark screen and dismisses only a showing lock screen")
    func wakeScripts() {
        #expect(AndroidAwakeState.wakeScript(screenOn: true, lockScreen: .hidden) == nil)
        #expect(AndroidAwakeState.wakeScript(screenOn: false, lockScreen: .hidden)?.sent == ["KEYCODE_WAKEUP"])
        #expect(AndroidAwakeState.wakeScript(screenOn: false, lockScreen: .secure)?.script == "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard")
        #expect(AndroidAwakeState.wakeScript(screenOn: true, lockScreen: .swipe)?.sent == ["dismiss-keyguard"])
    }

    @Test("a code is typed as quoted input text, then Enter only after every piece")
    func codeScript() throws {
        #expect(AndroidAwakeState.codeScript(try #require(UnlockCode("2580"))) == "input text '2580' && input keyevent KEYCODE_ENTER")
        #expect(AndroidAwakeState.codeScript(try #require(UnlockCode("it's a%sb"))) == #"input text 'it'\''s%sa%' && input text 'sb' && input keyevent KEYCODE_ENTER"#)
    }

    @Test("only a focused password field inside System UI counts as the lock screen's code field")
    func codeField() throws {
        func roots(_ xml: String) throws -> [UINode] {
            AndroidTreeMapping.roots(from: try UIAutomatorDump.parse(xml), scale: 2.625)
        }
        #expect(AndroidAwakeState.lockScreenCodeField(in: try roots(Self.dump()))?.id == "com.android.systemui:id/pinEntry")
        #expect(AndroidAwakeState.lockScreenCodeField(in: try roots(Self.dump(focused: false))) == nil)
        #expect(AndroidAwakeState.lockScreenCodeField(in: try roots(Self.dump(package: "com.example.app"))) == nil)
    }

    // MARK: Backend

    @Test("stay awake is one round trip that reports the earlier and new settings")
    func setStayAwake() async throws {
        let server = Self.server(states: ScriptedOutputs([Self.motoAwake])) { command in
            command == AndroidAwakeState.setScript(true) ? FakeAdbServer.shell(stdout: Self.motoAwake + AndroidAwakeState.afterMarker + "\n15\n") : nil
        }
        let (previous, current) = try await Self.backend(server).setStayAwake(true, on: Self.device)

        #expect(Self.shellCommands(server) == [AndroidAwakeState.setScript(true)])
        #expect(AndroidAwakeState.setScript(true).contains("settings put global stay_on_while_plugged_in 15"))
        #expect(previous.stayAwake.isEmpty)
        #expect(current.stayAwake == [.ac, .usb, .wireless, .dock])
    }

    @Test("wake sends nothing to a screen that is on and unlocked")
    func wakeUsable() async throws {
        let server = Self.server(states: ScriptedOutputs([Self.motoAwake]))
        let outcome = try await Self.backend(server).wake(on: Self.device)

        #expect(outcome.sent.isEmpty)
        #expect(Self.shellCommands(server) == [AndroidAwakeState.readScript])
    }

    @Test("wake turns a sleeping screen on behind a swipe lock and waits until it is usable")
    func wakeSwipe() async throws {
        let states = ScriptedOutputs([Self.state("Asleep", showing: true, secure: false), Self.state(showing: true, secure: false), Self.state(secure: false)])
        let server = Self.server(states: states)
        let outcome = try await Self.backend(server).wake(on: Self.device)

        #expect(outcome.sent == ["KEYCODE_WAKEUP", "dismiss-keyguard"])
        #expect(outcome.current.isUsable)
        #expect(Self.shellCommands(server).filter { $0 != AndroidAwakeState.readScript } == ["input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard"])
    }

    @Test("wake stops waiting for a secure lock screen soon after the screen is on")
    func wakeSecure() async throws {
        let server = Self.server(states: ScriptedOutputs([Self.state("Asleep", showing: true), Self.state(showing: true)]))
        let outcome = try await Self.backend(server).wake(on: Self.device)

        #expect(outcome.current.lockScreen == .secure)
        #expect(Self.shellCommands(server).filter { $0 == AndroidAwakeState.readScript }.count == 1 + AndroidBackend.securePolls)
    }

    @Test("a code is typed once into the focused lock screen field, then the device reads unlocked")
    func enterCode() async throws {
        let states = ScriptedOutputs([Self.state(showing: true), Self.motoAwake])
        let server = Self.server(states: states)
        let attempt = try await Self.backend(server).enterUnlockCode(try #require(UnlockCode("2580")), on: Self.device)

        #expect(attempt.typed)
        #expect(attempt.reading.isUsable)
        #expect(Self.shellCommands(server).filter { $0.hasPrefix("input") } == ["input text '2580' && input keyevent KEYCODE_ENTER"])
    }

    @Test("a lock screen that went dark between finding the field and typing gets nothing typed")
    func screenWentDark() async throws {
        let server = Self.server(states: ScriptedOutputs([Self.state("Asleep", showing: true)]))
        let attempt = try await Self.backend(server).enterUnlockCode(try #require(UnlockCode("2580")), on: Self.device)

        #expect(!attempt.typed)
        #expect(attempt.reading.screen == .off)
        #expect(!Self.shellCommands(server).contains { $0.hasPrefix("input") })
    }

    @Test("with no lock screen code field Offsider types nothing and says the device is locked")
    func noCodeField() async throws {
        let server = Self.server(states: ScriptedOutputs([Self.state(showing: true)]), dump: Self.dump(package: "com.example.app"))
        let error = await #expect(throws: AndroidError.self) {
            _ = try await Self.backend(server).enterUnlockCode(try #require(UnlockCode("2580")), on: Self.device)
        }

        #expect(error?.reason == .deviceLocked)
        #expect(!Self.shellCommands(server).contains { $0.hasPrefix("input") })
        #expect(Self.shellCommands(server).filter { $0 == "wm dismiss-keyguard" }.count == 2)
    }

    @Test("a failed code command reports the withheld label, never the code")
    func codeFailureWithheld() async throws {
        let server = Self.server(states: ScriptedOutputs([Self.state(showing: true)])) { command in
            command.hasPrefix("input text") ? FakeAdbServer.shell(stderr: "Error: 2580\n", status: 1) : nil
        }
        let error = await #expect(throws: AndroidError.self) {
            _ = try await Self.backend(server).enterUnlockCode(try #require(UnlockCode("2580")), on: Self.device)
        }

        #expect(error?.message.contains("2580") == false)
        #expect(error?.message.contains(AndroidAwakeState.codeLabel) == true)
    }
}
