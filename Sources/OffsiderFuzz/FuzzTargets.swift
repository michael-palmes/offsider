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
