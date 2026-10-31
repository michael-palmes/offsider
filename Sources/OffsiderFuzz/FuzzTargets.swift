import Foundation
@testable import OffsiderAndroid
@testable import OffsiderCore
@testable import OffsiderIOSDevice

/// One entry point per parser that reads bytes from a device, a daemon or a file someone else may write.
enum FuzzTargets {
    /// Each returns whether the input parsed, so a replay shows the seeds are still valid.
    static let all: [String: (Data) -> Bool] = [
        "shell-v2": shellV2,
        "helper-frame": helperFrame,
        "usbmux-frame": usbmuxFrame,
        "usbmux-http": usbmuxHTTP,
        "screencap-raw": screencapRaw,
        "uiautomator": uiautomator,
        "media-stream-answer": mediaStreamAnswer,
        "tree-cache-record": treeCacheRecord,
        "allow-list": allowList,
        "mask-config": maskConfig,
        "ordered-json": orderedJSON,
        "log-redactor": logRedactor,
        "android-notifications": androidNotifications,
        "dumpsys-package": dumpsysPackage,
        "dumpsys-display": dumpsysDisplay,
        "dumpsys-state": dumpsysState,
    ]

    /// A stream decoder sees the bytes in chunks; the first byte picks the chunk size so splits vary with the input.
    static func chunks(_ data: Data) -> [Data] {
        guard let first = data.first else { return [] }
        let size = Int(first % 64) + 1
        let rest = data.dropFirst()
        return stride(from: rest.startIndex, to: rest.endIndex, by: size).map { Data(rest[$0..<min($0 + size, rest.endIndex)]) }
    }

    static func shellV2(_ data: Data) -> Bool {
        var decoder = AdbWire.ShellV2Decoder(maxPacketBytes: 1 << 16)
        var packets = 0
        for chunk in chunks(data) {
            guard let decoded = try? decoder.feed(chunk) else { return false }
            precondition(decoder.bufferedCount <= 5 + (1 << 16) + chunk.count, "shell v2 decoder overbuffered")
            packets += decoded.count
        }
        return packets > 0
    }

    static func helperFrame(_ data: Data) -> Bool {
        var decoder = HelperWire.FrameDecoder()
        var frames = 0
        for chunk in chunks(data) {
            guard let decoded = try? decoder.feed(chunk) else { return false }
            for frame in decoded { _ = try? JSONSerialization.jsonObject(with: frame) }
            frames += decoded.count
        }
        return frames > 0
    }

    static func usbmuxFrame(_ data: Data) -> Bool {
        _ = try? UsbmuxFrame.header(data)
        guard let frame = try? UsbmuxFrame.decode(data) else { return false }
        _ = try? UsbmuxReply.devices(frame.payload)
        return (try? UsbmuxReply.dictionary(frame.payload)) != nil
    }

    static func usbmuxHTTP(_ data: Data) -> Bool {
        (try? UsbmuxHTTP.parseResponse(data)) != nil
    }

    static func screencapRaw(_ data: Data) -> Bool {
        _ = AndroidScreenCapture.warnsOfSeveralDisplays(data)
        guard let pixels = try? AndroidScreenCapture.pixels(fromScreencapRaw: data) else { return false }
        precondition(pixels.bytes.count == pixels.width * pixels.height * 4, "screencap pixels do not fill the image")
        return true
    }

    static func uiautomator(_ data: Data) -> Bool {
        (try? UIAutomatorDump.parse(String(decoding: data, as: UTF8.self))) != nil
    }

    static func mediaStreamAnswer(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        let output = mediaStreamValue(plist)
        let status = MediaStreamServerStatus.parse(output)
        return (try? MediaStreamAnswer.parse(output)) != nil || status.running
    }

    static func treeCacheRecord(_ data: Data) -> Bool {
        guard let record = try? TreeCacheRecord(data: data) else { return false }
        _ = try? TreeCacheRecord(data: record.encoded())
        return true
    }

    static func allowList(_ data: Data) -> Bool {
        guard let list = try? DeviceAllowList.parse(data) else { return false }
        _ = try? DeviceAllowList.parse(list.encoded())
        return true
    }

    static func maskConfig(_ data: Data) -> Bool {
        (try? MaskConfig.parse(data)) != nil
    }

    static func orderedJSON(_ data: Data) -> Bool {
        guard let value = try? OrderedJSON.parse(data) else { return false }
        _ = value.rendered(compact: true)
        return true
    }

    static func logRedactor(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        _ = LogRedactor.redactValue(text)
        return LogRedactor.redact(text).count > 0
    }

    /// The package the seeds under `android-notifications/` and `dumpsys-package/` name.
    static let dumpPackage = "com.mpalmes.offsider.playground.rn"

    static func androidNotifications(_ data: Data) -> Bool {
        guard let snapshot = AndroidNotifications.parse(String(decoding: data, as: UTF8.self), package: dumpPackage) else { return false }
        precondition(Set(snapshot.notifications.map(\.key)).count == snapshot.notifications.count, "a notification was listed twice")
        var redacted = 0
        let hidden = snapshot.notifications.map { notification -> PostedNotification in
            let values = [notification.title, notification.text, notification.bigText, notification.subText].compactMap { $0 }
            precondition(values.allSatisfy { $0.count <= AndroidNotifications.maximumValue }, "a notification value passed its cap")
            let result = notification.redacted()
            redacted += result.count
            _ = result.notification.contains("code")
            return result.notification
        }
        let report = NotificationReport.json(hidden, app: dumpPackage, source: snapshot.source, redacted: redacted, on: DeviceID(rawValue: "emulator-5554", platform: .android))
        precondition((try? JSONSerialization.jsonObject(with: Data(report.utf8))) != nil, "the notification report is not JSON")
        return true
    }

    static func dumpsysPackage(_ data: Data) -> Bool {
        let output = String(decoding: data, as: UTF8.self)
        let read = AndroidPackagePermissions.splitRead(output)
        let dump = String(read.dump)
        let permissions = AndroidPackagePermissions.parse(dumpsysPackage: dump, apiLevel: read.apiLevel, dangerous: AndroidPackagePermissions.parseDangerous(dump))
        _ = AndroidPackagePermissions.parse(dumpsysPackage: dump, apiLevel: read.apiLevel)
        _ = ExpoDevClient.schemes(fromPackageDump: dump)
        _ = AndroidAppPackage.state(in: output)
        let section = AndroidAppPackage.section(of: dumpPackage, in: dump)
        let info = AndroidAppPackage.info(output, package: dumpPackage)
        return section != nil || info != nil || !permissions.requested.isEmpty
    }

    static func dumpsysDisplay(_ data: Data) -> Bool {
        let output = String(decoding: data, as: UTF8.self)
        let list = AndroidDisplayList.parse(dumpsys: output)
        _ = AndroidDisplayGeometry.apiLevel(in: output)
        _ = AndroidDisplayGeometry.viewportUniqueId(in: output)
        let states = AndroidDeviceState.parseStates(output)
        let reading = AndroidDeviceState.parseReading(output)
        let geometry = try? AndroidDisplayGeometry.parse(output)
        return !list.displays.isEmpty || !states.isEmpty || reading != nil || geometry != nil
    }

    static func dumpsysState(_ data: Data) -> Bool {
        let output = String(decoding: data, as: UTF8.self)
        let foreground = AndroidForeground.parse(output)
        let enrolled = BiometricControl.parseAndroidEnrolled(output)
        let webView = AndroidDoctorRules.webViewVersion(fromDump: output)
        let set = AndroidAwakeState.parseSet(output)
        let reading = AndroidAwakeState.parse(output)
        return foreground.top != nil || enrolled != nil || webView != nil || set != nil || reading != nil
    }

    /// The same mapping the media stream tests use, from a plist to the XPC value the parser reads.
    static func mediaStreamValue(_ plist: Any, key: String? = nil) -> MediaStreamValue {
        switch plist {
        case let dictionary as [String: Any]:
            return .dictionary(dictionary.reduce(into: [:]) { result, entry in result[entry.key] = mediaStreamValue(entry.value, key: entry.key) })
        case let array as [Any]:
            return .array(array.map { mediaStreamValue($0) })
        case let data as Data:
            return .data(data)
        case let text as String:
            if key == "uuid", let uuid = UUID(uuidString: text) { return .uuid(uuid) }
            return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return number.int64Value < 0 ? .int(number.int64Value) : .uint(number.uint64Value)
        default:
            return .string("")
        }
    }
}
