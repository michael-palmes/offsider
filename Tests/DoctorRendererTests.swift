import Foundation
import Testing
import OffsiderCore

@Suite("Doctor Renderer Tests")
struct DoctorRendererTests {
    private let report = DoctorReport(
        offsiderVersion: "0.2.0",
        udid: "U1",
        xcode: XcodeSummary(developerDir: "/X", version: "27.0", build: "27A5218g", coreSimulator: "1155.4"),
        booted: [BootedSimulator(udid: "U1", name: "iPhone 17 Pro", osVersion: "iOS 27.0", deviceType: "iPhone 17 Pro")],
        checks: [
            DoctorCheckResult(id: .developerDir, status: .pass, detail: "/X (xcode-select)"),
            DoctorCheckResult(id: .deviceHub, status: .warn, detail: "Device Hub is not running", hint: "Open it", fixable: true),
            DoctorCheckResult(id: .dtuhidActiveFlag, status: .fail, detail: "Legacy keyboard is off", hint: "Reboot"),
            DoctorCheckResult(id: .hidTransport, status: .skip, detail: "simulator booted 4 s ago"),
            DoctorCheckResult(id: .stabilization, status: .pass, detail: "25 ms (default)", hint: "unused"),
        ],
        fixes: [DoctorFixResult(id: .deviceHub, action: "Open Device Hub", outcome: .applied, detail: "Opened Device Hub")]
    )

    private var lines: [String] {
        DoctorRenderer.render(report).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test("The header names Xcode and CoreSimulator")
    func header() {
        #expect(lines.first == "Offsider doctor: Xcode 27.0 (27A5218g), CoreSimulator 1155.4")
    }

    @Test("Each check renders on one line with its symbol and id")
    func checkLines() throws {
        let expected: [(String, String)] = [
            ("✓", "xcode.developer-dir"),
            ("!", "host.device-hub"),
            ("✗", "simulator.dtuhidd-active-flag"),
            ("-", "simulator.hid-transport"),
            ("✓", "hid.stabilization"),
        ]
        for (symbol, id) in expected {
            let line = try #require(lines.first { $0.hasPrefix("\(symbol) \(id) ") })
            #expect(line.contains(try #require(report.check(DoctorCheckID(rawValue: id)!)).detail))
        }
        #expect(lines.contains { $0.hasPrefix("- simulator.hid-transport") && $0.hasSuffix("Skipped: simulator booted 4 s ago") })
    }

    @Test("Warnings and failures with a hint get an indented Fix line; passes do not")
    func fixLines() {
        let fixLines = lines.filter { $0.hasPrefix("    Fix: ") }
        #expect(fixLines == ["    Fix: Open it", "    Fix: Reboot"])
        let deviceHubIndex = lines.firstIndex { $0.hasPrefix("! host.device-hub") }
        #expect(deviceHubIndex.map { lines[$0 + 1] } == "    Fix: Open it")
    }

    @Test("Booted simulators and applied fixes are listed")
    func bootedAndFixes() {
        #expect(lines.contains("Booted simulators:"))
        #expect(lines.contains { $0.hasPrefix("  iPhone 17 Pro") && $0.contains("U1") && $0.hasSuffix("iOS 27.0") })
        #expect(lines.contains("Fixes:"))
        #expect(lines.contains { $0.hasPrefix("  applied") && $0.contains("host.device-hub") && $0.hasSuffix("Opened Device Hub") })
    }

    @Test("The result line counts warnings and failures")
    func resultLine() {
        #expect(lines.last(where: { !$0.isEmpty }) == "Result: 1 warning, 1 failure")
        let clean = DoctorReport(
            offsiderVersion: "0.2.0",
            udid: nil,
            xcode: XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil),
            booted: [],
            checks: [DoctorCheckResult(id: .developerDir, status: .pass, detail: "ok")]
        )
        let text = DoctorRenderer.render(clean)
        #expect(text.contains("Booted simulators: none"))
        #expect(!text.contains("Fixes:"))
        #expect(text.hasSuffix("Result: no problems found\n"))
    }
}
