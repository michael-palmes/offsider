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

    @Test("output without the script's own marker is not read as an empty list")
    func noMarkerIsAnError() {
        #expect(AndroidNotifications.parse("/system/bin/sh: cmd: not found\n", package: Self.package) == nil)
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
}
