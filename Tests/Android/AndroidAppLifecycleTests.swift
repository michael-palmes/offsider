import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android app lifecycle")
@MainActor
struct AndroidAppLifecycleTests {
    static let package = "com.mpalmes.offsider.playground.rn"
    static let device = AndroidBackendTests.device

    /// Android 16's layout: the install time sits under `User 0:`, and the runtime grant after it.
    static let android16Dump = """
    Activity Resolver Table:
      Non-Data Actions:
          android.intent.action.MAIN:
            2bb56f3 com.mpalmes.offsider.playground.rn/.MainActivity filter 4b4ad30

    Packages:
      Package [com.mpalmes.offsider.playground.rn] (82b83b):
        appId=10214
        versionCode=7 minSdk=24 targetSdk=36
        minExtensionVersions=[]
        versionName=1.0.0 (beta)
        flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP ]
        timeStamp=2026-10-28 11:32:20
        lastUpdateTime=2026-10-28 11:32:20
        installerPackageName=com.android.vending
        initiatingPackageName=com.android.vending
        requested permissions:
          android.permission.POST_NOTIFICATIONS
        User 0: ceDataInode=344923 installed=true hidden=false suspended=false stopped=false notLaunched=false enabled=0
          firstInstallTime=2026-10-22 00:28:38
          runtime permissions:
            android.permission.POST_NOTIFICATIONS: granted=true, flags=[ USER_SET|USER_SENSITIVE_WHEN_GRANTED]
            android.permission.CAMERA: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED]

    Queries:
      system apps queryable: false
    """

    /// Android 8.1's layout, behind the warning line some phones print first: install time at the package's level, no installer for adb.
    static let android8Dump = """
    WARNING: linker: Warning: unable to normalize ""
    Packages:
      Package [com.mpalmes.offsider.playground.rn] (4a1c2e0):
        userId=10123
        versionCode=3 minSdk=21 targetSdk=27
        versionName=0.9.1
        flags=[ DEBUGGABLE HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP ]
        timeStamp=2026-10-27 08:59:59
        firstInstallTime=2026-10-27 09:00:01
        lastUpdateTime=2026-10-27 09:00:02
        User 0: ceDataInode=1209 installed=true hidden=false suspended=false stopped=false notLaunched=false enabled=0 instant=false
          runtime permissions:
    """

    static func infoReply(_ dump: String, zone: String, sdk: Int) -> String {
        dump + "\n\(AndroidAppPackage.zoneMarker)\n\(zone)\n\(sdk)\n"
    }

    static func setUp(_ reply: @escaping @Sendable (String) -> FakeAdbServer.Reply) throws -> (AndroidBackend, FakeAdbServer) {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            [device.rawValue],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in
                let command = service.hasPrefix("shell,v2,raw:") ? String(service.dropFirst("shell,v2,raw:".count)) : service
                return reply(command)
            }
        ))
        return (try AndroidBackendTests.backend(server), server)
    }

    static func shellCommands(_ server: FakeAdbServer) -> [String] {
        server.services.filter { $0.hasPrefix("shell,v2,raw:") }.map { String($0.dropFirst("shell,v2,raw:".count)) }
    }

    @Test("dumpsys package gives the version, build, installer, install times in the device's zone, the notification grant and the build type")
    func parsesAndroid16() throws {
        let info = try #require(AndroidAppPackage.info(Self.infoReply(Self.android16Dump, zone: "Asia/Tokyo", sdk: 36), package: Self.package))
        #expect(info.version == "1.0.0 (beta)")
        #expect(info.build == "7")
        #expect(info.installer == "com.android.vending")
        #expect(info.firstInstalled.map(ProcessStamp.timestamp) == "2026-10-21T15:28:38Z")
        #expect(info.lastUpdated.map(ProcessStamp.timestamp) == "2026-10-28T02:32:20Z")
        #expect(info.notifications == true)
        #expect(info.debuggable == false)
    }

    @Test("Android 8.1's dump reads the same fields, with no installer and no notification grant before Android 13")
    func parsesAndroid8() throws {
        let info = try #require(AndroidAppPackage.info(Self.infoReply(Self.android8Dump, zone: "Etc/UTC", sdk: 27), package: Self.package))
        #expect(info.version == "0.9.1")
        #expect(info.build == "3")
        #expect(info.installer == nil)
        #expect(info.firstInstalled.map(ProcessStamp.timestamp) == "2026-10-27T09:00:01Z")
        #expect(info.notifications == nil)
        #expect(info.debuggable == true)
    }

    @Test("without the device's time zone the install times are left out rather than guessed")
    func noZoneNoTimes() throws {
        let info = try #require(AndroidAppPackage.info(Self.infoReply(Self.android16Dump, zone: "", sdk: 36), package: Self.package))
        #expect(info.firstInstalled == nil && info.lastUpdated == nil)
        #expect(info.version == "1.0.0 (beta)")
    }

    @Test("another package's section is never read as this app's")
    func otherPackageIgnored() {
        let dump = Self.android16Dump.replacingOccurrences(of: "Package [\(Self.package)]", with: "Package [com.example.other]")
        #expect(AndroidAppPackage.info(Self.infoReply(dump, zone: "Etc/UTC", sdk: 36), package: Self.package) == nil)
    }

    @Test("app info on a device without the app is app_not_installed")
    func infoNotInstalled() async throws {
        let (backend, _) = try Self.setUp { _ in FakeAdbServer.shell(stdout: "Dexopt state:\n\n\(AndroidAppPackage.zoneMarker)\nEtc/UTC\n36\n") }
        let error = await #expect(throws: AndroidError.self) { _ = try await backend.appInfo(Self.package, on: Self.device) }
        #expect(error?.kind == .appNotInstalled)
    }

    @Test("launch starts the launcher activity with the launcher's flags and reports a cold start and its time")
    func launchCold() async throws {
        let (backend, server) = try Self.setUp { _ in
            FakeAdbServer.shell(stdout: """
            offsider: stopped
            Starting: Intent { act=android.intent.action.MAIN cat=[android.intent.category.LAUNCHER] cmp=com.mpalmes.offsider.playground.rn/.MainActivity }
            Status: ok
            LaunchState: COLD
            Activity: com.mpalmes.offsider.playground.rn/.MainActivity
            TotalTime: 412
            WaitTime: 420
            Complete
            """)
        }
        let launch = try await backend.launchApp(Self.package, restart: false, on: Self.device)
        #expect(launch == AppLaunch(app: Self.package, start: .cold, restarted: false, milliseconds: 412))
        let script = try #require(Self.shellCommands(server).last)
        #expect(script.contains("am start -W -f 0x10200000 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n \"$c\""))
        #expect(script.contains("case \"$c\" in \"$p\"/*)"))
        #expect(!script.contains("am force-stop"))
    }

    @Test("launch of a running app is warm, from LaunchState or, before Android 10, from the process check")
    func launchWarm() async throws {
        let (backend, _) = try Self.setUp { _ in
            FakeAdbServer.shell(stdout: "offsider: running\nWarning: Activity not started, its current task has been brought to the front\nStatus: ok\nThisTime: 0\nComplete\n")
        }
        let launch = try await backend.launchApp(Self.package, restart: false, on: Self.device)
        #expect(launch.start == .warm)
        #expect(AndroidAppPackage.start(launchState: "HOT", wasRunning: false, restarted: false) == .warm)
        #expect(AndroidAppPackage.start(launchState: "UNKNOWN", wasRunning: false, restarted: false) == .cold)
        #expect(AndroidAppPackage.start(launchState: nil, wasRunning: true, restarted: true) == .cold)
    }

    @Test("an app already in front reports a warm start and no launch time, as Android starts nothing")
    func launchAlreadyInFront() async throws {
        let (backend, _) = try Self.setUp { _ in
            FakeAdbServer.shell(stdout: """
            offsider: running
            Warning: Activity not started, intent has been delivered to currently running top-most instance.
            Status: ok
            LaunchState: UNKNOWN (0)
            TotalTime: 0
            WaitTime: 1
            Complete
            """)
        }
        let launch = try await backend.launchApp(Self.package, restart: false, on: Self.device)
        #expect(launch.start == .warm && launch.milliseconds == nil)
    }

    @Test("launch --restart force-stops the app in the same shell call, before it starts")
    func launchRestart() async throws {
        let (backend, server) = try Self.setUp { _ in FakeAdbServer.shell(stdout: "offsider: running\nStatus: ok\nLaunchState: COLD\nTotalTime: 900\n") }
        let launch = try await backend.launchApp(Self.package, restart: true, on: Self.device)
        #expect(launch.start == .cold && launch.restarted)
        let script = try #require(Self.shellCommands(server).last)
        let stop = try #require(script.range(of: "am force-stop \"$p\""))
        let start = try #require(script.range(of: "am start -W"))
        #expect(stop.lowerBound < start.lowerBound)
    }

    @Test("an app with no launcher activity is refused with a pointer to app open")
    func noLauncher() async throws {
        let (backend, _) = try Self.setUp { _ in FakeAdbServer.shell(stdout: "offsider: stopped\noffsider: no-launcher\n") }
        let error = await #expect(throws: AppLifecycleError.self) { _ = try await backend.launchApp(Self.package, restart: false, on: Self.device) }
        #expect(error?.kind == .noLauncher)
        #expect(error?.message.contains("offsider app open") == true)
    }

    @Test("an app that is not installed is app_not_installed, and nothing is started")
    func launchNotInstalled() async throws {
        let (backend, _) = try Self.setUp { _ in FakeAdbServer.shell(stdout: "offsider: not-installed\n") }
        let error = await #expect(throws: AndroidError.self) { _ = try await backend.launchApp(Self.package, restart: false, on: Self.device) }
        #expect(error?.kind == .appNotInstalled)
    }

    @Test("stop says whether the app was running")
    func stop() async throws {
        let (backend, server) = try Self.setUp { _ in FakeAdbServer.shell(stdout: "offsider: stopped\n") }
        #expect(try await backend.terminateApp(Self.package, on: Self.device) == AppStop(app: Self.package, wasRunning: false))
        #expect(try #require(Self.shellCommands(server).last).contains("am force-stop \"$p\""))
    }

    @Test("open sends the link single-quoted, so & ; and ' reach the app whole, and limits the intent to the package")
    func openQuotesLink() async throws {
        let link = "https://example.com/offer?id=7&ref=push;x=it's"
        let (backend, server) = try Self.setUp { _ in FakeAdbServer.shell(stdout: "offsider: running\nStatus: ok\nLaunchState: WARM\nTotalTime: 120\n") }
        let launch = try await backend.openLink(link, in: Self.package, restart: false, on: Self.device)
        #expect(launch.start == .warm && launch.milliseconds == 120)
        let script = try #require(Self.shellCommands(server).last)
        #expect(script.contains(#"am start -W -a android.intent.action.VIEW -d 'https://example.com/offer?id=7&ref=push;x=it'\''s' "$p""#))
        #expect(script.contains("p='\(Self.package)'"))
    }

    @Test("a link the app has no screen for is link_not_handled")
    func openUnresolved() async throws {
        let (backend, _) = try Self.setUp { _ in
            FakeAdbServer.shell(stdout: "offsider: stopped\nStarting: Intent { act=android.intent.action.VIEW dat=https://example.com/... pkg=com.mpalmes.offsider.playground.rn }\nError: Activity not started, unable to resolve Intent { act=android.intent.action.VIEW dat=https://example.com/... flg=0x10000000 pkg=com.mpalmes.offsider.playground.rn }\n")
        }
        let error = await #expect(throws: AppLifecycleError.self) { _ = try await backend.openLink("https://example.com/a", in: Self.package, restart: false, on: Self.device) }
        #expect(error?.kind == .linkNotHandled)
    }

    @Test("a refused scheme never reaches the device")
    func openRefusedScheme() async throws {
        let (backend, server) = try Self.setUp { _ in FakeAdbServer.shell(stdout: "offsider: running\nStatus: ok\n") }
        await #expect(throws: AppLifecycleError.self) { _ = try await backend.openLink("intent://x#Intent;component=com.example/.Evil;end", in: Self.package, restart: false, on: Self.device) }
        #expect(Self.shellCommands(server).isEmpty)
    }
}
