import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android notifications")
struct AndroidNotificationsTests {
    static let package = "com.mpalmes.offsider.playground.rn"
    static let other = "com.example.chat"

    /// `cmd notification get`'s layout (Android 16): the record at the margin, its extras deeper.
    static func record(_ package: String, id: Int, tag: String, title: String, text: String, flags: String = "0", indent: String = "") -> String {
        let key = "0|\(package)|\(id)|\(tag)|10214"
        return """
        \(indent)NotificationRecord(0x0015b7e1: pkg=\(package) user=UserHandle{0} id=\(id) tag=\(tag) importance=3 key=\(key): Notification(channel=alerts shortcut=null contentView=null vibrate=null sound=null defaults=0 flags=\(flags) color=0x00000000 vis=PRIVATE))
        \(indent)  uid=10214 userId=0
        \(indent)  notification=
        \(indent)        when=1793162588428/1793162588428
        \(indent)        extras={
        \(indent)            android.title=String (\(title))
        \(indent)            android.reduced.images=Boolean (true)
        \(indent)            android.text=String (\(text))
        \(indent)            android.appInfo=ApplicationInfo (ApplicationInfo{4c0906 \(package)})
        \(indent)            android.bigText=null
        \(indent)        }
        \(indent)  mCreationTimeMs=1793162588433
        """
    }

    /// Runs the device script under /bin/sh with `cmd` and `dumpsys` stubbed from `stubs`, as the phone's shell would run it.
    static func runScript(stubs: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", stubs + "\n" + AndroidNotifications.script(package: package)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("on Android 11 and later only the app's own keys are fetched, never a key whose tag merely holds the package")
    func keyPathFetchesOnlyTheAppsKeys() throws {
        let stubs = """
        cmd() {
          case "$2" in
            list) printf '%s\\n' '0|\(Self.package)|7|alerts|10214' '0|\(Self.other)|3|x|\(Self.package)|y|10300' '-1|android|1|null|1000' ;;
            get) case "$3" in "0|\(Self.package)|"*) echo "RECORD FOR $3" ;; *) echo "LEAKED $3" ;; esac ;;
          esac
        }
        """
        let output = try Self.runScript(stubs: stubs)
        #expect(output.contains(AndroidNotifications.keysMarker))
        #expect(output.contains("RECORD FOR 0|\(Self.package)|7|alerts|10214"))
        #expect(!output.contains("LEAKED"))
    }

    @Test("before Android 11 the dump is filtered on the device to the app's records in the active list")
    func dumpPathFiltersOnTheDevice() throws {
        let dump = """
        Current Notification Manager state:
          Notification List:
        \(Self.record(Self.other, id: 3, tag: "x", title: "Message from Sam", text: "See you at 6", indent: "    "))
        \(Self.record(Self.package, id: 7, tag: "alerts", title: "Order filled", text: "Bought 1\nat 2.50", indent: "    "))
        \(Self.record(Self.package, id: 8, tag: "second", title: "Second alert", text: "Sold 1", indent: "    "))
          Snoozed notifications:
        \(Self.record(Self.package, id: 9, tag: "later", title: "Snoozed one", text: "hidden", indent: "    "))
         Notification Preferences:
        """
        let stubs = """
        cmd() { return 255; }
        dumpsys() { cat <<'DUMP'
        \(dump)
        DUMP
        }
        """
        let output = try Self.runScript(stubs: stubs)
        #expect(output.contains(AndroidNotifications.dumpMarker))
        #expect(output.contains("Order filled"))
        #expect(!output.contains("Sam") && !output.contains("See you"))
        #expect(!output.contains("Snoozed one"))
        let snapshot = try #require(AndroidNotifications.parse(output, package: Self.package))
        #expect(snapshot.source == .dump)
        #expect(snapshot.notifications.map(\.title) == ["Order filled", "Second alert"])
        #expect(snapshot.notifications.first?.text == "Bought 1\nat 2.50")
    }

    @Test("a record gives its key, id, tag, channel, title, text and post time")
    func parsesRecord() throws {
        let output = [AndroidNotifications.keysMarker, AndroidNotifications.recordMarker, Self.record(Self.package, id: 7, tag: "alerts", title: "Order filled (AUD)", text: "Bought 1 at 2.50 & sold")].joined(separator: "\n")
        let snapshot = try #require(AndroidNotifications.parse(output, package: Self.package))
        let notification = try #require(snapshot.notifications.first)
        #expect(snapshot.source == .keys)
        #expect(notification.key == "0|\(Self.package)|7|alerts|10214")
        #expect(notification.id == 7 && notification.tag == "alerts" && notification.channel == "alerts")
        #expect(notification.title == "Order filled (AUD)")
        #expect(notification.text == "Bought 1 at 2.50 & sold")
        #expect(notification.bigText == nil)
        #expect(notification.postedAt.map(ProcessStamp.timestamp) == ProcessStamp.timestamp(Date(timeIntervalSince1970: 1_793_162_588.433)))
        #expect(!notification.ongoing)
    }

    @Test("text that runs over several lines is kept whole, up to the next extra")
    func multilineText() throws {
        let output = [AndroidNotifications.keysMarker, AndroidNotifications.recordMarker, Self.record(Self.package, id: 7, tag: "t", title: "Two lines", text: "first\nsecond")].joined(separator: "\n")
        #expect(try #require(AndroidNotifications.parse(output, package: Self.package)).notifications.first?.text == "first\nsecond")
    }

    @Test("a record of another package, Android's own group summaries and records with no text are left out")
    func skipsOthers() throws {
        let output = [
            AndroidNotifications.keysMarker,
            AndroidNotifications.recordMarker, Self.record(Self.other, id: 3, tag: "x", title: "Message from Sam", text: "hi"),
            AndroidNotifications.recordMarker, Self.record(Self.package, id: 0, tag: "g", title: "", text: "", flags: "LOCAL_ONLY|GROUP_SUMMARY|AUTOGROUP_SUMMARY"),
            AndroidNotifications.recordMarker, Self.record(Self.package, id: 9, tag: "live", title: "Live price", text: "2.51", flags: "ONGOING_EVENT|NO_CLEAR"),
            AndroidNotifications.recordMarker, Self.record(Self.package, id: 9, tag: "live", title: "Live price", text: "2.51", flags: "ONGOING_EVENT|NO_CLEAR"),
        ].joined(separator: "\n")
        let notifications = try #require(AndroidNotifications.parse(output, package: Self.package)).notifications
        #expect(notifications.map(\.title) == ["Live price"])
        #expect(notifications.first?.ongoing == true)
    }

    @Test("output without the script's own marker, or a dump with no active list, is not read as an empty list")
    func noMarkerIsAnError() {
        #expect(AndroidNotifications.parse("/system/bin/sh: cmd: not found\n", package: Self.package) == nil)
        #expect(AndroidNotifications.parse("\(AndroidNotifications.dumpMarker)\n", package: Self.package) == nil)
        #expect(AndroidNotifications.parse("\(AndroidNotifications.dumpMarker)\n\(AndroidNotifications.listMarker)\n", package: Self.package)?.notifications == [])
    }

    @Test("a mask file's value patterns and emails reach notification text, and count")
    func maskFileReachesText() throws {
        let mask = TreeValueMask(patterns: [try MaskPlan.compile(#"rc-\d{4}"#)], emails: true)
        let (hidden, count) = PostedNotification(key: "k", title: "Code rc-5521", text: "Sent to me@example.com").redacted(mask)

        #expect(hidden.title == "Code [redacted]")
        #expect(hidden.text == "Sent to [redacted email]")
        #expect(count == 2)
        #expect(!hidden.contains("rc-5521"))
    }

    @Test("a code in a tag is hidden in the tag and the key; the raw key stays for telling notifications apart")
    func tagAndKey() throws {
        let raw = PostedNotification(key: "0|\(Self.package)|1|otp-482915|10214", tag: "otp-482915")
        let (hidden, count) = raw.redacted()

        #expect(hidden.tag?.contains("482915") == false)
        #expect(!hidden.key.contains("482915"))
        #expect(hidden.key.hasPrefix("0|\(Self.package)|1|") && hidden.key.hasSuffix("|10214"))
        #expect(count == 1)
        #expect(raw.key.contains("482915"))
    }

    @Test("--json marks the key untrusted, since it repeats the app's tag")
    func keyIsUntrusted() throws {
        let line = NotificationReport.json([PostedNotification(key: "k")], app: Self.package, source: .keys, redacted: 0, on: DeviceID(rawValue: "emulator-5554", platform: .android))
        #expect(line.contains(#""notifications[].key""#))
    }

    @Test("one-time codes are hidden and counted, and --wait matches the hidden text, so it cannot probe for a code")
    func redaction() {
        let notification = PostedNotification(key: "k", title: "Your code", text: "Your verification code is 482915")
        let (hidden, count) = notification.redacted()
        #expect(count == 1)
        #expect(hidden.text?.contains("482915") == false)
        #expect(hidden.contains("verification code"))
        #expect(!hidden.contains("482915"))
    }

    @Test("JSON lists each notification with the app's text marked untrusted")
    func json() throws {
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        let text = NotificationReport.json([PostedNotification(key: "k", id: 1, title: "Hi", text: "There")], app: Self.package, source: .keys, redacted: 0, on: device)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["source"] as? String == "keys")
        #expect((object["notifications"] as? [[String: Any]])?.first?["title"] as? String == "Hi")
        #expect((object["untrusted"] as? [String])?.contains("notifications[].title") == true)
    }

    /// `cmd notification get` on Android 16, captured from an emulator and trimmed: extras at 8 spaces, their brace at 4, a value's later lines at the margin.
    static let capturedRecord = """
    NotificationRecord(0x076258c5: pkg=com.mpalmes.offsider.playground.rn user=UserHandle{0} id=2020 tag=vshape importance=3 key=0|com.mpalmes.offsider.playground.rn|2020|vshape|2000: Notification(channel=shell_cmd shortcut=null contentView=null vibrate=null sound=null defaults=0 flags=0 color=0x00000000 vis=PRIVATE))
      uid=2000 userId=0
      flags=SILENT
      key=0|com.mpalmes.offsider.playground.rn|2020|vshape|2000
      notification=
        when=1793434196228/1793434196228
        extras={
            android.title=String (Filled order (test))
            android.reduced.images=Boolean (true)
            android.template=String (android.app.Notification$BigTextStyle)
            android.text=String (Ready (today)
    Shopping list:
      Indented:
    Total 5.00)
            android.appInfo=ApplicationInfo (ApplicationInfo{94a021a com.mpalmes.offsider.playground.rn})
            android.showWhen=Boolean (true)
            android.bigText=null
        }
      publicNotification=
        None
      mCreationTimeMs=1793434196231
    """

    static func text(_ value: String, extraLine: String = "android.appInfo=ApplicationInfo (x)") throws -> String? {
        let record = """
        NotificationRecord(0x1: pkg=\(package) user=UserHandle{0} id=1 tag=t importance=3 key=0|\(package)|1|t|2000: Notification(channel=a flags=0))
          notification=
            extras={
                android.title=String (Title)
                android.text=String (\(value))
                \(extraLine)
            }
          mCreationTimeMs=1793434196231
        """
        return try #require(AndroidNotifications.parse([AndroidNotifications.keysMarker, AndroidNotifications.recordMarker, record].joined(separator: "\n"), package: package)).notifications.first?.text
    }

    @Test("a captured record keeps every line of its text, its own brackets and later lines that look like headers")
    func capturedShape() throws {
        let output = [AndroidNotifications.keysMarker, AndroidNotifications.recordMarker, Self.capturedRecord].joined(separator: "\n")
        let snapshot = try #require(AndroidNotifications.parse(output, package: Self.package))
        let notification = try #require(snapshot.notifications.first)
        #expect(notification.title == "Filled order (test)")
        #expect(notification.text == "Ready (today)\nShopping list:\n  Indented:\nTotal 5.00")
        #expect(notification.bigText == nil)
    }

    @Test("a first or middle line ending in ) does not end the text", arguments: ["Ready (today)\nTotal 5.00", "a\nb (c)\nd", "(x)\n(y)\n(z)"])
    func lineEndingInBracket(_ value: String) throws {
        #expect(try Self.text(value) == value)
    }

    @Test("an extra of any key ends the text, not only android. keys", arguments: ["androidx.core.app.extra.COMPAT_TEMPLATE=String (x)", "gcm.n.e=String (1)", "orderId=Integer (5)"])
    func nonAndroidExtraEndsValue(_ line: String) throws {
        #expect(try Self.text("Ready (today)", extraLine: line) == "Ready (today)")
    }

    @Test("a text line that looks like a key or a brace, but not at the entry's indent, stays in the text")
    func lookalikesStay() throws {
        #expect(try Self.text("{\n  \"total\": 5\n}") == "{\n  \"total\": 5\n}")
        #expect(try Self.text("(a)\nkey=value\nend") == "(a)\nkey=value\nend")
    }

    @Test("a value with no closing bracket stops at the cap")
    func unterminatedValueIsCapped() throws {
        let lines = (0..<2_000).map { "line \($0)" }.joined(separator: "\n")
        let record = "NotificationRecord(0x1: pkg=\(Self.package) user=UserHandle{0} id=1 tag=t importance=3 key=0|\(Self.package)|1|t|2000: Notification(channel=a flags=0))\n        android.text=String (\(lines)"
        let output = [AndroidNotifications.keysMarker, AndroidNotifications.recordMarker, record].joined(separator: "\n")
        let snapshot = try #require(AndroidNotifications.parse(output, package: Self.package))
        #expect(snapshot.notifications.first?.text?.count == AndroidNotifications.maximumValue)
    }

    static let noApp = "pm() { :; }"
    static let hasApp = "pm() { echo package:/data/app/base.apk; }"

    @Test("with no key of the app, pm path tells a mistyped package from an app with nothing posted", arguments: [(Self.noApp, true), (Self.hasApp, false)])
    func keyPathChecksInstalled(pm: String, missing: Bool) throws {
        let output = try Self.runScript(stubs: "\(pm)\ncmd() { echo '0|\(Self.other)|3|x|10300'; }")
        #expect(AndroidNotifications.notInstalled(output) == missing)
        #expect(AndroidNotifications.parse(output, package: Self.package)?.notifications == [])
    }

    @Test("before Android 11 the same check runs once the filter found no record", arguments: [(Self.noApp, true), (Self.hasApp, false)])
    func dumpPathChecksInstalled(pm: String, missing: Bool) throws {
        let stubs = """
        \(pm)
        cmd() { return 255; }
        dumpsys() { printf '  Notification List:\\n  Usage Stats:\\n'; }
        """
        #expect(AndroidNotifications.notInstalled(try Self.runScript(stubs: stubs)) == missing)
    }

    @Test("an app with a record pays for no pm path, on either path")
    func recordSkipsThePackageCheck() throws {
        let probe = "pm() { echo PM-RAN; }"
        let keys = try Self.runScript(stubs: "\(probe)\ncmd() { case \"$2\" in list) echo '0|\(Self.package)|7|a|10214' ;; get) echo RECORD ;; esac; }")
        #expect(!keys.contains("PM-RAN"))
        let dump = """
        \(probe)
        cmd() { return 255; }
        dumpsys() { cat <<'DUMP'
          Notification List:
        \(Self.record(Self.package, id: 7, tag: "a", title: "T", text: "x", indent: "    "))
          Usage Stats:
        DUMP
        }
        """
        #expect(!(try Self.runScript(stubs: dump)).contains("PM-RAN"))
    }

    @Test("a line of the app's own text cannot read as not installed")
    func markerInTextIsNotTheMarker() {
        let output = [AndroidNotifications.keysMarker, AndroidNotifications.recordMarker, AndroidNotifications.notInstalledMarker].joined(separator: "\n")
        #expect(!AndroidNotifications.notInstalled(output))
    }

    @Test("a package that is not installed is app_not_installed, not an empty list")
    @MainActor
    func backendThrowsNotInstalled() async throws {
        let (backend, _) = try AndroidAppLifecycleTests.setUp { _ in FakeAdbServer.shell(stdout: "\(AndroidNotifications.keysMarker)\n\(AndroidNotifications.notInstalledMarker)\n") }
        let error = await #expect(throws: AndroidError.self) { _ = try await backend.notifications(of: "com.exmaple.app", on: AndroidAppLifecycleTests.device) }
        #expect(error?.kind == .appNotInstalled)
    }

    @Test("the install check runs once a read has confirmed the app, so a --wait pays for one pm path and a later failed one cannot end it")
    @MainActor
    func installCheckRunsOnce() async throws {
        let (backend, server) = try AndroidAppLifecycleTests.setUp { _ in FakeAdbServer.shell(stdout: "\(AndroidNotifications.keysMarker)\n") }
        _ = try await backend.notifications(of: Self.package, on: AndroidAppLifecycleTests.device)
        _ = try await backend.notifications(of: Self.package, on: AndroidAppLifecycleTests.device)
        let scripts = AndroidAppLifecycleTests.shellCommands(server).filter { $0.contains("cmd notification list") }
        #expect(scripts.count == 2)
        #expect(scripts[0].contains("pm path"))
        #expect(!scripts[1].contains("pm path"))
    }

    /// The tail of an Android 16 dump, captured from an emulator: settings lines, the archive, then headers at one and two spaces.
    static func dump(_ records: String, archive: String = "  mArchive=Archive (0 notifications)") -> String {
        """
        Current Notification Manager state:
          Notification List:
        \(records)
          mMaxPackageEnqueueRate=5.0
          hideSilentStatusBar=false
        \(archive)
          Enqueued Notification List:
          Snoozed notifications:
        \(Self.record(Self.package, id: 9, tag: "later", title: "Snoozed one", text: "hidden", indent: "    "))
         Notification Preferences:
        PackagePreferences:
        """
    }

    static func runDump(_ dump: String) throws -> String {
        try runScript(stubs: """
        cmd() { return 255; }
        dumpsys() { cat <<'DUMP'
        \(dump)
        DUMP
        }
        """)
    }

    @Test("another app's line ending in : at the margin does not drop this app's later records")
    func otherAppsColonLine() throws {
        let output = try Self.runDump(Self.dump("""
        \(Self.record(Self.other, id: 3, tag: "x", title: "Chat", text: "Hi Sam\nShopping list:\nmilk", indent: "    "))
        \(Self.record(Self.package, id: 7, tag: "a", title: "Order filled", text: "Bought 1", indent: "    "))
        """))
        #expect(!output.contains("Hi Sam") && !output.contains("Shopping list") && !output.contains("milk"))
        let snapshot = try #require(AndroidNotifications.parse(output, package: Self.package))
        #expect(snapshot.notifications.map(\.title) == ["Order filled"])
    }

    @Test("this app's own line ending in : at the margin keeps its text whole")
    func ownColonLine() throws {
        let output = try Self.runDump(Self.dump(Self.record(Self.package, id: 7, tag: "a", title: "List", text: "Hi Sam\nShopping list:\nmilk", indent: "    ")))
        let snapshot = try #require(AndroidNotifications.parse(output, package: Self.package))
        #expect(snapshot.notifications.first?.text == "Hi Sam\nShopping list:\nmilk")
    }

    @Test("a text line at one or two spaces ending in : still ends the list, so the filter fails closed and shows no other app's text", arguments: ["  Shopping list:", " Shopping list:"])
    func indentedColonLineFailsClosed(_ line: String) throws {
        let output = try Self.runDump(Self.dump("""
        \(Self.record(Self.other, id: 3, tag: "x", title: "Chat", text: "Hi Sam\n\(line)\nmilk", indent: "    "))
        \(Self.record(Self.package, id: 7, tag: "a", title: "Order filled", text: "Bought 1", indent: "    "))
        """))
        #expect(!output.contains("Hi Sam") && !output.contains("milk"))
        #expect(try #require(AndroidNotifications.parse(output, package: Self.package)).notifications.isEmpty)
    }

    @Test("the archive after the list does not reach the cable, in either Android's wording", arguments: ["  mArchive (2 notifications)", "  mArchive=Archive (2 notifications)"])
    func archiveEndsTheList(_ header: String) throws {
        let archive = "\(header)\n    StatusBarNotification(pkg=\(Self.other) user=UserHandle{0} id=3 tag=x)"
        let output = try Self.runDump(Self.dump(Self.record(Self.package, id: 7, tag: "a", title: "Order filled", text: "Bought 1", indent: "    "), archive: archive))
        #expect(!output.contains(Self.other))
    }
}
