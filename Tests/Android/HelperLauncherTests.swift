import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android helper launcher")
@MainActor
struct HelperLauncherTests {
    static let devicePath = "/data/local/tmp/offsider-helper-9d0fbf9349f646f1.dex"

    static func launcher(_ device: FakeHelperDevice, server: FakeAdbServer? = nil) -> HelperLauncher {
        HelperLauncher(
            client: AdbClient(endpoint: .defaultAdbServer, connector: server ?? device.server()),
            serial: FakeHelperDevice.serial,
            dex: FakeHelperDevice.dex,
            log: { _, _ in },
            hostPid: 777
        )
    }

    static func failure(_ device: FakeHelperDevice) async -> HelperStartFailure? {
        do {
            let started = try await launcher(device).launch()
            await started.shell.close()
            return nil
        } catch let failure as HelperStartFailure {
            return failure
        } catch {
            Issue.record("expected a HelperStartFailure, got \(error)")
            return nil
        }
    }

    @Test("the start script checks the dex's SHA-256 where sha256sum exists, else its size, then execs app_process under the helper's name")
    func startScript() {
        let script = HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: nil)
        #expect(script == """
        f='\(Self.devicePath)'; [ -f "$f" ] && [ ! -L "$f" ] || exit 90; \
        if command -v sha256sum >/dev/null 2>&1; then case "$(sha256sum "$f" 2>/dev/null)" in \(FakeHelperDevice.dex.sha256)\\ *) ;; *) exit 90;; esac; \
        else [ "$(stat -c %s "$f" 2>/dev/null)" = 3 ] || exit 90; fi; \
        CLASSPATH="$f" exec app_process /data/local/tmp --nice-name=offsider-helper com.mpalmes.offsider.helper.OffsiderHelper serve \
        --idle-timeout-ms 10000 --accept-timeout-ms 10000
        """)
    }

    @Test("after a push the script moves the copy out of the private push folder, makes it 644, removes the folder and every other copy before the digest check")
    func startScriptAfterPush() {
        let script = HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: "/data/local/tmp/offsider-push-777")
        #expect(script.hasPrefix("""
        f='\(Self.devicePath)'; mv -f '/data/local/tmp/offsider-push-777'/helper.dex "$f" && chmod 644 "$f"; rm -rf '/data/local/tmp/offsider-push-777'; \
        for o in /data/local/tmp/offsider-helper-*.dex; do [ "$o" = "$f" ] || rm -f "$o"; done; [ -f "$f" ]
        """))
        #expect(script.contains("in \(FakeHelperDevice.dex.sha256)\\ *) ;; *) exit 90;; esac;"))
    }

    @Test("the push folder is made 0700 by the shell user, replacing any stale one")
    func pushDirectory() {
        #expect(Self.launcher(FakeHelperDevice()).pushDirectory == "/data/local/tmp/offsider-push-777")
        #expect(HelperLauncher.makePushDirectoryScript("/data/local/tmp/offsider-push-777") == "rm -rf '/data/local/tmp/offsider-push-777' && mkdir -m 700 '/data/local/tmp/offsider-push-777'")
    }

    @Test("a missing or mismatched dex (exit 90) is pushed once, 0600, into a fresh 0700 folder, then started from its final name")
    func pushesOnMissing() async throws {
        let device = FakeHelperDevice(dexOnDevice: false)
        let started = try await Self.launcher(device).launch()
        await started.shell.close()

        #expect(started.ready.pid == 4002)
        #expect(device.timeline.filter { !$0.hasPrefix("shell closed") } == [
            "start 1", "mkdir /data/local/tmp/offsider-push-777", "push /data/local/tmp/offsider-push-777/helper.dex,33152", "start 2 after push",
        ])
        #expect(device.syncSessions.count == 1)
        #expect(device.syncSessions.first?.file == FakeHelperDevice.dexBytes)
        #expect(device.startScripts.last?.contains("mv -f '/data/local/tmp/offsider-push-777'/helper.dex \"$f\"") == true)
    }

    @Test("a push folder that cannot be made is a push failure, and nothing is pushed")
    func pushFolderRefused() async {
        let device = FakeHelperDevice(dexOnDevice: false)
        device.mkdirFails = true
        let failure = await Self.failure(device)
        #expect(failure == .unavailable(.pushFailed("could not make /data/local/tmp/offsider-push-777: mkdir: Permission denied")))
        #expect(device.syncSessions.isEmpty)
    }

    @Test("a dex already on the device starts without a push")
    func noPushWhenPresent() async throws {
        let device = FakeHelperDevice()
        let started = try await Self.launcher(device).launch()
        await started.shell.close()
        #expect(device.syncSessions.isEmpty)
        #expect(device.startScripts.count == 1)
    }

    @Test("a second exit 90 after the push is a push failure")
    func secondMissing() async {
        let device = FakeHelperDevice(dexOnDevice: false)
        device.pushLands = false
        let failure = await Self.failure(device)
        #expect(failure == .unavailable(.pushFailed("the helper was still missing after the push")))
        #expect(device.syncSessions.count == 1)
    }

    @Test("a FAIL from sync is a push failure quoting the device")
    func syncFails() async {
        let device = FakeHelperDevice(dexOnDevice: false)
        device.syncAnswer = .fail("couldn't create file: Read-only file system")
        let failure = await Self.failure(device)
        #expect(failure == .unavailable(.pushFailed("couldn't create file: Read-only file system")))
        #expect(device.startScripts.count == 1)
    }

    static let busyJSON = #"{"ok":false,"error":{"code":"uiautomation-busy","message":"another UiAutomation client is connected","detail":"java.lang.IllegalStateException: UiAutomationService already registered!"}}"#

    static let startTable: [(FakeHelperDevice.Start, HelperStartFailure)] = [
        (.exit(status: 2, stdout: #"{"ok":false,"error":{"code":"usage","message":"unknown option '--x'","detail":null}}"#), .unavailable(.handshake("unknown option '--x'"))),
        (.exit(status: 3, stdout: #"{"ok":false,"error":{"code":"hidden-api-unavailable","message":"UiAutomation(Looper, IUiAutomationConnection) is missing","detail":"java.lang.NoSuchMethodException: init"}}"#),
         .unavailable(.hiddenAPI("UiAutomation(Looper, IUiAutomationConnection) is missing (java.lang.NoSuchMethodException: init)"))),
        (.exit(status: 4, stdout: busyJSON + "\n", stderr: "offsider-helper: uiautomation-busy: another client\n"), .busy(detail: "java.lang.IllegalStateException: UiAutomationService already registered!")),
        (.exit(status: 5, stdout: #"{"ok":false,"error":{"code":"connect-failed","message":"UiAutomation connect failed","detail":null}}"#), .unavailable(.connectFailed("UiAutomation connect failed"))),
        (.exit(status: 6, stdout: #"{"ok":false,"error":{"code":"crashed","message":"unexpected error","detail":"java.lang.NullPointerException"}}"#), .unavailable(.crashed(status: 6, detail: "unexpected error"))),
        (.exit(status: 127, stderr: "/system/bin/sh: app_process: inaccessible or not found\n"), .unavailable(.crashed(status: 127, detail: "/system/bin/sh: app_process: inaccessible or not found"))),
        (.exit(status: 137), .unavailable(.crashed(status: 137, detail: "no output"))),
        (.readyWithProtocol(3), .unavailable(.handshake("the helper on the device speaks protocol 3, Offsider speaks 2"))),
        (.silent, .unavailable(.noReady(seconds: 30))),
    ]

    @Test("every way a start can fail before the ready line is classified", arguments: startTable.indices)
    func classifies(row: Int) async {
        let (start, expected) = Self.startTable[row]
        let device = FakeHelperDevice(starts: [start])
        #expect(await Self.failure(device) == expected)
        #expect(device.timeline.contains("shell closed 1"), "the start shell is closed, so a waiting helper ends")
    }

    @Test("stdout lines that are not the ready line are skipped")
    func skipsNoise() async throws {
        let device = FakeHelperDevice(starts: [.readyAfter(["WARNING: linker: unused DT entry", #"{"note":"not ready"}"#])])
        let started = try await Self.launcher(device).launch()
        await started.shell.close()
        #expect(started.ready.token == "token-1")
    }

    @Test("a device error, such as the serial going away, propagates unchanged")
    func deviceErrors() async {
        let device = FakeHelperDevice()
        let gone = FakeAdbServer(handler: FakeAdbServer.devices([], device: { _, _ in .hang }))
        let error = await #expect(throws: AndroidError.self) { _ = try await Self.launcher(device, server: gone).launch() }
        #expect(error?.kind == .serialNotRunning)
    }

    @Test("the reasons read as the fallback warning quotes them")
    func reasonText() {
        #expect(HelperUnavailableReason.noReady(seconds: 30).description == "it did not start within 30 s")
        #expect(HelperUnavailableReason.crashed(status: 6, detail: "boom").description == "it exited with status 6 before it was ready: boom")
        #expect(HelperUnavailableReason.pushFailed("x").description == "pushing it to /data/local/tmp failed: x")
        #expect(HelperUnavailableReason.handshake("x").description == "its socket did not answer: x")
    }
}
