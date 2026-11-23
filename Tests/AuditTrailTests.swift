import CryptoKit
import Darwin
import Foundation
@testable import OffsiderCore
import Testing

@Suite("Audit trail file")
struct AuditTrailTests {
    static func event(_ outcome: AuditRecord.Outcome = .ran, key: String = PolicyFixtures.serial) -> AuditEvent {
        AuditEvent(outcome, platform: .android, key: key, app: AuditFixtures.playground, exit: 0)
    }

    static func sha(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func withHome<T>(_ body: (String) throws -> T) throws -> T {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        return try body(home)
    }

    static func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    @Test("the first line links to the genesis hash and each later line to the SHA-256 of the line before it")
    func chainLinks() throws {
        try Self.withHome { home in
            let trail = AuditFixtures.trail(home: home)
            trail.record([Self.event()])
            trail.record([Self.event(.refused), Self.event(.sessionStopped)])
            let lines = AuditFixtures.lines(home)
            let prevs = try AuditFixtures.objects(home).map { try #require($0["prev"] as? String) }
            #expect(prevs == [AuditTrail.genesis, Self.sha(lines[0]), Self.sha(lines[1])])
            #expect(lines.allSatisfy { $0.hasPrefix("{\"prev\":\"") })
            #expect(trail.verify() == .intact(lines: 3))
        }
    }

    @Test("a record carries the clock's time, the build, the process, the session, the command path and the hashed device key")
    func recordFields() throws {
        try Self.withHome { home in
            let capture = AuditCapture()
            AuditFixtures.trail(home: home, command: "app launch", capture: capture).record([
                AuditEvent(.refused, platform: .ios, key: PolicyFixtures.phone, exit: 7, reason: "device_not_allowed", refusal: "expired", testDevice: true, managed: true),
            ])
            let object = try #require(try AuditFixtures.objects(home).first)
            #expect(object["time"] as? String == "2026-09-21T14:14:20Z")
            #expect(object["version"] as? String == "0.18.0" && object["pid"] as? Int == 4242 && object["command"] as? String == "app launch")
            #expect((object["session"] as? [String: Any])?["name"] as? String == "node")
            #expect(object["device"] as? String == AuditRecord.deviceKey(platform: .ios, key: PolicyFixtures.phone))
            #expect(object["device"] as? String == String(TreeCacheRecord.fileName(platform: .ios, device: PolicyFixtures.phone).dropLast(".json".count)))
            #expect(object["outcome"] as? String == "refused" && object["exit"] as? Int == 7 && object["refusal"] as? String == "expired")
            #expect(object["testDevice"] as? Bool == true && object["managed"] as? Bool == true && object["ms"] as? Int == 12)
            #expect(capture.records.count == 1 && capture.records[0].refusal == "expired")
            #expect(AuditRecord.parse(Data(AuditFixtures.lines(home)[0].utf8))?.record == capture.records[0])
        }
    }

    @Test("the hand-written line is the same JSON the general renderer gives, with every field and with none of the optional ones")
    func lineMatchesRenderer() {
        let full = AuditRecord(
            AuditEvent(.allowed, platform: .ios, key: PolicyFixtures.phone, app: AuditFixtures.playground, exit: 7, reason: "device_not_allowed", refusal: "expired", testDevice: true,
                       managed: true, expires: PolicyFixtures.now, pins: 2),
            time: PolicyFixtures.now, version: "0.18.0-3-gabc1234", pid: 4242, session: AuditRecord.Session(pid: 7, name: "node"), command: "app launch", milliseconds: 12
        )
        let bare = AuditRecord(AuditEvent(.ran, platform: .android, key: "K"), time: PolicyFixtures.now, version: "0.18.0", pid: 1, session: nil, command: "tap", milliseconds: nil)
        for record in [full, bare] {
            #expect(record.line(prev: AuditTrail.genesis) == record.json(prev: AuditTrail.genesis).rendered(compact: true))
            #expect(AuditRecord.parse(Data(record.line(prev: AuditTrail.genesis).utf8))?.record == record)
        }
    }

    @Test("a record's time reads exactly as every other Offsider timestamp does", arguments: [0, 951_782_400, 1_709_251_199, 1_790_000_060.9, 4_102_444_799])
    func stampMatchesTimestamps(seconds: Double) {
        let date = Date(timeIntervalSince1970: seconds)
        #expect(AuditRecord.stamp(date) == ProcessStamp.timestamp(date))
    }

    @Test("an edited line, a removed line and a cut start each break the chain where it happened")
    func tamperBreaksChain() throws {
        try Self.withHome { home in
            let trail = AuditFixtures.trail(home: home)
            for _ in 0..<4 { trail.record([Self.event()]) }
            let path = AuditFixtures.path(home)
            let lines = AuditFixtures.lines(home)

            var edited = lines
            edited[1] = edited[1].replacingOccurrences(of: "\"outcome\":\"ran\"", with: "\"outcome\":\"refused\"")
            try (edited.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            #expect(trail.verify() == .broken(file: AuditTrail.fileName, line: 3))

            try ([lines[0], lines[2], lines[3]].joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            #expect(trail.verify() == .broken(file: AuditTrail.fileName, line: 2))

            try (lines.dropFirst().joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            #expect(trail.verify() == .broken(file: AuditTrail.fileName, line: 1))

            try (lines.joined(separator: "\n") + "\nnot a record\n").write(toFile: path, atomically: true, encoding: .utf8)
            #expect(trail.verify() == .broken(file: AuditTrail.fileName, line: 5))
        }
    }

    @Test("at the size cap the file is renamed to .1 and the next chain starts from its last line's hash; one older file is kept")
    func rotation() throws {
        try Self.withHome { home in
            let trail = AuditFixtures.trail(home: home, maximumBytes: 1500)
            for _ in 0..<5 { trail.record([Self.event()]) }
            let kept = AuditFixtures.lines(home, rotated: true)
            let current = try AuditFixtures.objects(home)
            #expect(!kept.isEmpty && !current.isEmpty && kept.count + current.count == 5)
            #expect(current[0]["prev"] as? String == Self.sha(try #require(kept.last)))
            #expect(trail.verify() == .intact(lines: 5))
            #expect(AuditFixtures.text(home).utf8.count <= 1500 && AuditFixtures.text(home, rotated: true).utf8.count <= 1500)

            for _ in 0..<8 { trail.record([Self.event()]) }
            let files = try FileManager.default.contentsOfDirectory(atPath: AuditFixtures.folder(home)).filter { $0.hasPrefix(AuditTrail.fileName) }.sorted()
            #expect(files == [AuditTrail.fileName, AuditTrail.rotatedName])
            guard case .intact(let lines) = trail.verify() else {
                Issue.record("the chain broke across a second rotation: \(trail.verify())")
                return
            }
            #expect(lines == AuditFixtures.lines(home).count + AuditFixtures.lines(home, rotated: true).count)
            #expect(trail.last(3).count == 3 && trail.last(1000).count == lines)
        }
    }

    @Test("with the kept file removed, the current file no longer starts a chain, so the cut shows")
    func missingKeptFile() throws {
        try Self.withHome { home in
            let trail = AuditFixtures.trail(home: home, maximumBytes: 1500)
            for _ in 0..<6 { trail.record([Self.event()]) }
            try FileManager.default.removeItem(atPath: AuditFixtures.path(home, rotated: true))
            #expect(trail.verify() == .broken(file: AuditTrail.fileName, line: 1))
        }
    }

    @Test("the file is 0600 in a 0700 folder, and a looser mode is tightened by the next record")
    func privateFile() throws {
        try Self.withHome { home in
            let trail = AuditFixtures.trail(home: home)
            #expect(trail.fileState() == .none && trail.verify() == .none)
            trail.record([Self.event()])
            #expect(Self.mode(AuditFixtures.path(home)) == 0o600 && Self.mode(AuditFixtures.folder(home)) == 0o700)
            #expect(trail.fileState() == .safe(bytes: AuditFixtures.text(home).utf8.count))

            chmod(AuditFixtures.path(home), 0o644)
            #expect(trail.fileState() == .readableByOthers)
            trail.record([Self.event()])
            #expect(Self.mode(AuditFixtures.path(home)) == 0o600 && trail.verify() == .intact(lines: 2))
        }
    }

    @Test("a symlink or a folder in the file's place is never written through: the problem is reported and the mirror still gets the record")
    func unsafeFileRefused() throws {
        try Self.withHome { home in
            let capture = AuditCapture()
            let trail = AuditFixtures.trail(home: home, capture: capture)
            try FileManager.default.createDirectory(atPath: AuditFixtures.folder(home), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let elsewhere = home + "/elsewhere.txt"
            try "".write(toFile: elsewhere, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: AuditFixtures.path(home), withDestinationPath: elsewhere)
            trail.record([Self.event()])
            #expect(try String(contentsOfFile: elsewhere, encoding: .utf8).isEmpty)
            #expect(capture.problems.count == 1 && capture.records.count == 1)
            guard case .unusable = trail.fileState() else {
                Issue.record("a symlink read as \(trail.fileState())")
                return
            }

            try FileManager.default.removeItem(atPath: AuditFixtures.path(home))
            try FileManager.default.createDirectory(atPath: AuditFixtures.path(home), withIntermediateDirectories: false)
            trail.record([Self.event()])
            #expect(capture.problems.count == 2 && capture.records.count == 2)
        }
    }

    @Test("an account with no home folder writes no file and still mirrors each record")
    func noHome() {
        let capture = AuditCapture()
        let trail = AuditTrail(directory: nil, stamp: { AuditTrail.Stamp(version: "0.18.0", pid: 1) }, mirror: capture.mirror, problem: capture.problem)
        trail.record([Self.event()])
        #expect(capture.records.count == 1 && capture.problems.isEmpty && trail.fileState() == .none && trail.verify() == .none && trail.last(5).isEmpty)
    }

    @Test("the newest records come back oldest first, and one device's alone when asked")
    func lastRecords() throws {
        try Self.withHome { home in
            let trail = AuditFixtures.trail(home: home)
            trail.record([Self.event(.allowed), Self.event(.ran, key: "OTHER123"), Self.event(.refused), Self.event(.withdrawn)])
            #expect(trail.last(2).map(\.outcome) == [.refused, .withdrawn])
            #expect(trail.last(10, device: AuditRecord.deviceKey(platform: .android, key: "OTHER123")).map(\.outcome) == [.ran])
            #expect(trail.last(0).count == 1)
        }
    }

    @Test("a file that does not end in a newline gets the next record on its own line, and the damaged line shows as the break")
    func partialLastLine() throws {
        try Self.withHome { home in
            let trail = AuditFixtures.trail(home: home)
            trail.record([Self.event()])
            let handle = try #require(FileHandle(forWritingAtPath: AuditFixtures.path(home)))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"prev\":\"cut".utf8))
            try handle.close()
            trail.record([Self.event(.refused)])
            let lines = AuditFixtures.lines(home)
            #expect(lines.count == 3 && lines[2].hasPrefix("{\"prev\":\"\(Self.sha(lines[1]))\""))
            #expect(trail.verify() == .broken(file: AuditTrail.fileName, line: 2))
            #expect(trail.last(5).map(\.outcome) == [.ran, .refused])
        }
    }

    @Test("writers in parallel never interleave or fork the chain")
    func parallelWriters() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let capture = AuditCapture()
        let trail = AuditFixtures.trail(home: home, maximumBytes: 6000, capture: capture)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<25 { trail.record([Self.event()]) }
                }
            }
        }
        #expect(capture.problems.isEmpty, "\(capture.problems.prefix(3))")
        guard case .intact = trail.verify() else {
            Issue.record("parallel writers broke the chain: \(trail.verify())")
            return
        }
    }

    @Test("one record costs well under a millisecond")
    func cost() throws {
        try Self.withHome { home in
            let trail = AuditFixtures.trail(home: home)
            trail.record([Self.event()])
            var samples: [UInt64] = []
            for _ in 0..<200 {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                trail.record([Self.event()])
                samples.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
            }
            let median = samples.sorted()[samples.count / 2]
            #expect(median < AuditFixtures.costBudget, "the median record took \(median / 1000) µs")
        }
    }
}

@Suite("Audit trail doctor checks")
struct AuditDoctorRulesTests {
    @Test("a Mac with no audit trail passes both checks")
    func freshMacPasses() throws {
        try AuditTrailTests.withHome { home in
            let trail = AuditFixtures.trail(home: home)
            let checks = AuditDoctorRules.checks(file: trail.fileState(), chain: trail.verify())
            #expect(checks.map(\.id) == [.auditFile, .auditChain])
            #expect(checks.allSatisfy { $0.status == .pass && $0.hint == nil })
        }
    }

    @Test("an intact trail passes with its size and record count")
    func intactPasses() {
        #expect(AuditDoctorRules.file(.safe(bytes: 4096)).status == .pass)
        #expect(AuditDoctorRules.chain(.intact(lines: 1)).detail == "1 record, each linked to the one before")
        #expect(AuditDoctorRules.chain(.intact(lines: 12)).detail.hasPrefix("12 records"))
    }

    @Test("a file others can read, an unusable file, a broken chain and an unreadable trail each warn, and no hint removes the trail")
    func problemsWarn() {
        let verdicts = [
            AuditDoctorRules.file(.readableByOthers), AuditDoctorRules.file(.unusable("device-audit.log is not a regular file")),
            AuditDoctorRules.chain(.broken(file: AuditTrail.fileName, line: 7)), AuditDoctorRules.chain(.unreadable("device-audit.log: tooLarge")),
        ]
        #expect(verdicts.allSatisfy { $0.status == .warn && $0.hint != nil })
        #expect(verdicts.allSatisfy { $0.hint?.contains("rm ") == false })
        #expect(verdicts[0].hint == AuditDoctorRules.tightenCommand)
        #expect(verdicts[2].detail.contains("line 7") && verdicts[2].hint?.contains(AuditTrail.logPredicate) == true)
    }
}
