import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Simulator crash loops")
struct SimulatorCrashLoopTests {
    static let udid = "0A1B2C3D-0000-4000-8000-000000000001"
    static let other = "11111111-2222-3333-4444-555555555555"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func report(process: String, coalition: String, timestamp: String = "2026-10-04 14:07:49.00 +1030") -> String {
        """
        {"app_name":"\(process)","timestamp":"\(timestamp)","bug_type":"309","name":"\(process)"}
        {
          "uptime" : 150,
          "procName" : "\(process)",
          "coalitionName" : "\(coalition)",
          "threads" : [{"frames" : [{"symbol" : "abort"}]}]
        }
        """
    }

    static func crashes(_ process: String, _ count: Int, udid: String = udid, minutesAgo: Double = 1) -> [SimulatorCrash] {
        (0..<count).map { _ in SimulatorCrash(udid: udid, process: process, timestamp: now.addingTimeInterval(-minutesAgo * 60)) }
    }

    @Test("a simulator report yields its UDID, process and header timestamp")
    func parsesSimulatorReport() throws {
        let text = Self.report(process: "PosterBoard", coalition: "com.apple.CoreSimulator.SimDevice.\(Self.udid)")
        let crash = try #require(SimulatorCrashReports.parse(text, modified: Self.now))
        #expect(crash.udid == Self.udid)
        #expect(crash.process == "PosterBoard")
        #expect(crash.timestamp == Date(timeIntervalSince1970: 1791085069))
    }

    @Test("a macOS app's report is ignored")
    func ignoresHostReports() {
        let text = Self.report(process: "Safari", coalition: "com.apple.Safari")
        #expect(SimulatorCrashReports.parse(text, modified: Self.now) == nil)
    }

    @Test("crashes older than ten minutes do not count")
    func windowExcludesOldCrashes() {
        let crashes = Self.crashes("PosterBoard", 5, minutesAgo: 11) + Self.crashes("routined", 1, minutesAgo: 9)
        #expect(SimulatorCrashReports.recent(crashes, now: Self.now).map(\.process) == ["routined"])
    }

    @Test("no crashes passes, one or two warns, three or more fails with the erase command")
    func thresholds() {
        #expect(DoctorRules.crashLoop([], udid: Self.udid).status == .pass)
        #expect(DoctorRules.crashLoop(Self.crashes("PosterBoard", 9, udid: Self.other), udid: Self.udid).status == .pass)

        let warn = DoctorRules.crashLoop(Self.crashes("AppIntentsLiveEntityService", 2), udid: Self.udid)
        #expect(warn.status == .warn)
        #expect(warn.detail == "AppIntentsLiveEntityService crashed 2 times in the last 10 minutes")

        let fail = DoctorRules.crashLoop(Self.crashes("PosterBoard", 25) + Self.crashes("routined", 1), udid: Self.udid)
        #expect(fail.status == .fail)
        #expect(fail.detail == "PosterBoard crashed 25 times in the last 10 minutes; routined crashed 1 time in the last 10 minutes")
        #expect(fail.hint?.contains("xcrun simctl shutdown \(Self.udid) && xcrun simctl erase \(Self.udid)") == true)
        #expect(fail.hint?.contains("removes its apps and settings") == true)
    }

    @Test("the host check names each looping simulator and ignores ones below three crashes")
    func hostListsLoopingSimulators() {
        let crashes = Self.crashes("PosterBoard", 3) + Self.crashes("routined", 2, udid: Self.other)
        let verdict = DoctorRules.crashLoops(crashes, names: [Self.udid: "Offsider E2E iPhone"])
        #expect(verdict.status == .warn)
        #expect(verdict.detail == "Offsider E2E iPhone (\(Self.udid)): PosterBoard crashed 3 times in the last 10 minutes")
        #expect(DoctorRules.crashLoops(Self.crashes("routined", 2), names: [:]).status == .pass)
    }

    @Test("the probe reads recent simulator reports and skips old files and other extensions")
    func probeReadsRecentReports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        let stamp = formatter.string(from: now)
        let coalition = "com.apple.CoreSimulator.SimDevice.\(Self.udid)"
        let files: [(String, String, TimeInterval)] = [
            ("PosterBoard-1.ips", Self.report(process: "PosterBoard", coalition: coalition, timestamp: stamp), 0),
            ("PosterBoard-2.ips", Self.report(process: "PosterBoard", coalition: coalition, timestamp: stamp), -1200),
            ("PosterBoard-3.txt", Self.report(process: "PosterBoard", coalition: coalition, timestamp: stamp), 0),
        ]
        for (name, text, age) in files {
            let url = directory.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(age)], ofItemAtPath: url.path)
        }
        let crashes = DoctorProbes.recentSimulatorCrashes(now: now, directory: directory.path)
        #expect(crashes.map(\.process) == ["PosterBoard"])
        #expect(crashes.first?.udid == Self.udid)

        let fresh = SimulatorCrashReports.parse(Self.report(process: "PosterBoard", coalition: coalition, timestamp: "bad"), modified: now)
        #expect(fresh?.timestamp == now, "an unreadable header timestamp falls back to the file's modification time")
    }
}
