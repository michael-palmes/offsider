import Foundation
import OffsiderCore
import Testing

/// Every write a console makes, in order, for a test to read back.
final class ConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [(stream: Console.Stream, text: String)] = []

    var write: @Sendable (Console.Stream, String) -> Void {
        { [self] stream, text in lock.withLock { writes.append((stream, text)) } }
    }

    var all: [(stream: Console.Stream, text: String)] { lock.withLock { writes } }
    var out: String { all.filter { $0.stream == .out }.map(\.text).joined() }
    var err: String { all.filter { $0.stream == .err }.map(\.text).joined() }

    /// A console that writes here, as `out` and `err` read it.
    func console(out: Console.Channel, err: Console.Channel) -> Console {
        Console(out: out, err: err, write: write)
    }
}

/// Synthetic listings and pages the screen goldens, layout and agent output tests share.
enum ScreenFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// `HH:mm` in UTC, so a golden reads the same in every time zone.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func simulator(_ number: Int, _ name: String, state: String = "Shutdown", os: String = "iOS 26.0") -> DeviceSummary {
        DeviceSummary(id: "00000000-0000-4000-8000-00000000000\(number)", platform: .ios, state: state, name: name, osVersion: os, deviceType: name, kind: .simulator)
    }

    static var devices: [DeviceSummary] {
        var emulator = DeviceSummary(
            id: "emulator-5554", platform: .android, state: "Booted", name: "Pixel_9", osVersion: "Android 16", deviceType: "pixel_9", kind: .emulator, avd: "Pixel_9"
        )
        emulator.lease = DeviceLease(label: "PR 123", created: now, expires: now.addingTimeInterval(3_600), pid: 4242)
        var phone = DeviceSummary(
            id: "R58M123ABC", platform: .android, state: "Booted", name: "Pixel 8", osVersion: nil, deviceType: "Physical (USB)", kind: .physical, connection: "usb"
        )
        phone.allowed = true
        let avd = DeviceSummary(
            id: "Medium_Phone_API_37", platform: .android, state: "Shutdown", name: "Medium_Phone_API_37", osVersion: "Android API 37", deviceType: "medium_phone",
            kind: .avd, avd: "Medium_Phone_API_37"
        )
        return DeviceListOrder.sorted([
            simulator(2, "iPad Air 13-inch (M3)"), simulator(1, "iPhone 17 Pro", state: "Booted"), simulator(3, "iPhone 17e", state: "Booting"),
            emulator, phone, avd,
        ])
    }

    static let untrusted = ListingSkip(
        what: "iPhones and iPads", message: "This Xcode is not trusted, so Offsider will not run its tools. Choose an Xcode that Apple signed.",
        hint: "sudo xcode-select -s /Applications/Xcode.app"
    )

    static var mixed: DeviceListing {
        DeviceListing(devices: devices, hiddenPhysical: 3, skipped: [untrusted])
    }

    static let empty = DeviceListing(devices: [])

    /// One booted simulator and nothing else: a person's next step exports it.
    static var single: DeviceListing {
        DeviceListing(devices: [simulator(1, "iPhone 17 Pro", state: "Booted")])
    }

    static func page(_ listing: DeviceListing) -> Page {
        DevicesScreen.page(listing, now: now, clock: clock)
    }

    /// Every kind of block and notice, so a renderer change shows on one page.
    static let kitchenSink = Page([
        .person([.header(Header(.doctor, "Check this Mac", ["1 warning"]))]),
        .fields([Field("Xcode", Table.Cell("27.0")), Field("Device", Table.Cell("Pixel 8", untrusted: true, tag: "allowed"))]),
        .prose("Run `offsider doctor --device emulator-5554` to check one device, or pass `--json` for every detail."),
        .outcome(.done("Appearance dark", details: ["was light"])),
        .outcome(.failed("Could not reach the emulator", details: ["It stopped answering."])),
        .commands(title: "Next", [Shortcut("offsider devices", "See devices and their IDs")]),
        .agent("legacy line\n"),
    ], notices: [
        .warning("adb is old", agent: "adb 34.0.0 is older than 35.0.0; update Platform-Tools.", try: "sdkmanager platform-tools"),
        .note("1 phone hidden until a person allows it", agent: "1 physical device is hidden; a person can list it with offsider devices --physical.", mark: .lock, see: "offsider devices --physical"),
        .next("export OFFSIDER_DEVICE=emulator-5554"),
    ])

    static var pages: [(name: String, page: Page)] {
        [
            ("devices mixed", page(mixed)), ("devices empty", page(empty)), ("devices single", page(single)),
            ("start", StartScreen.page(version: "0.13.0")), ("kitchen sink", kitchenSink),
        ]
    }
}

/// Each screen's renders under `Goldens/screens`, checked or, with `OFFSIDER_GOLDENS_UPDATE=1`, rewritten.
enum ScreenGoldens {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens/screens")

    static func text(_ capture: ConsoleCapture) -> String {
        (capture.out + "#stderr\n" + capture.err).replacingOccurrences(of: "\u{1B}", with: "\\e")
    }

    /// Fails when `actual` differs from the committed golden; with `OFFSIDER_GOLDENS_UPDATE=1` writes it instead.
    static func check(_ path: String, _ actual: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = root.appendingPathComponent(path)
        if TreeGoldens.isUpdating {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(actual.utf8).write(to: url)
            return
        }
        let expected = try #require(
            try? String(decoding: Data(contentsOf: url), as: UTF8.self), "No golden at \(path): run OFFSIDER_GOLDENS_UPDATE=1 swift test --filter ScreenGoldenTests",
            sourceLocation: sourceLocation
        )
        #expect(actual == expected, "\(path) changed; review it, then run OFFSIDER_GOLDENS_UPDATE=1 swift test --filter ScreenGoldenTests", sourceLocation: sourceLocation)
    }
}
