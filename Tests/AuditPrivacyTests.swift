import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

/// Collects what a trail mirrors and reports, in place of the unified log and stderr.
final class AuditCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var mirrored: [AuditRecord] = []
    private var reported: [String] = []
    private var built = 0

    var records: [AuditRecord] { lock.withLock { mirrored } }
    var problems: [String] { lock.withLock { reported } }
    var stamps: Int { lock.withLock { built } }

    func mirror(_ record: AuditRecord) { lock.withLock { mirrored.append(record) } }
    func problem(_ text: String) { lock.withLock { reported.append(text) } }
    func stamped() { lock.withLock { built += 1 } }
}

enum AuditFixtures {
    static let playground = "com.mpalmes.offsider.playground.rn"

    /// A trail in a temporary home, with a fixed clock and no unified log.
    static func trail(
        home: String, now: Date = PolicyFixtures.now, command: String? = "tap", version: String = "0.18.0", session: AuditRecord.Session? = AuditRecord.Session(pid: 77, name: "node"),
        maximumBytes: Int = AuditTrail.maximumBytes, capture: AuditCapture = AuditCapture()
    ) -> AuditTrail {
        AuditTrail(
            directory: UserConfigDirectory(home: home), maximumBytes: maximumBytes, now: { now },
            stamp: {
                capture.stamped()
                return AuditTrail.Stamp(version: version, pid: 4242, session: session, command: command, milliseconds: 12)
            },
            mirror: capture.mirror, problem: capture.problem
        )
    }

    static func folder(_ home: String) -> String { home + "/.config/offsider" }
    static func path(_ home: String, rotated: Bool = false) -> String { folder(home) + "/" + (rotated ? AuditTrail.rotatedName : AuditTrail.fileName) }

    static func text(_ home: String, rotated: Bool = false) -> String {
        (try? String(contentsOfFile: path(home, rotated: rotated), encoding: .utf8)) ?? ""
    }

    static func lines(_ home: String, rotated: Bool = false) -> [String] {
        text(home, rotated: rotated).split(separator: "\n").map(String.init)
    }

    static func objects(_ home: String, rotated: Bool = false) throws -> [[String: Any]] {
        try lines(home, rotated: rotated).map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    static func outcomes(_ home: String) throws -> [String] {
        try objects(home).compactMap { $0["outcome"] as? String }
    }
}

@Suite("Audit trail privacy")
struct AuditPrivacyTests {
    /// What must never reach a record: screen labels, values, typed text, tree text, device names and ids, and arguments.
    static let canaries = [
        "Sign in to Example Bank", "hunter2-typed-text", "Canary Phone of Sam", "Balance $1,234.00", PolicyFixtures.phone, PolicyFixtures.serial, "--text", "/Volumes/canary/secret.txt",
        "A label with spaces",
    ]

    static func matches(_ value: Any, _ pattern: String) -> Bool {
        guard let text = value as? String else { return false }
        return text.wholeMatch(of: try! Regex(pattern)) != nil
    }

    static func isInteger(_ value: Any, _ range: ClosedRange<Int>) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let integer = value as? Int else { return false }
        return range.contains(integer)
    }

    static func isBool(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    static let stampPattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#

    /// The only shape each key's value may take. A new field needs a line here, and none of these shapes fits free text.
    static let shapes: [String: @Sendable (Any) -> Bool] = [
        "prev": { matches($0, "[0-9a-f]{64}") },
        "time": { matches($0, stampPattern) },
        "version": { matches($0, #"unknown|\d{1,5}\.\d{1,5}(\.\d{1,5})?(-[0-9A-Za-z.+_-]{1,40})?"#) },
        "pid": { isInteger($0, 0...Int(Int32.max)) },
        "session": { value in
            guard let session = value as? [String: Any], Set(session.keys) == ["pid", "name"], let pid = session["pid"], let name = session["name"] else { return false }
            return isInteger(pid, 0...Int(Int32.max)) && matches(name, #"[0-9A-Za-z._-]{1,16}"#)
        },
        "command": { matches($0, "[a-z0-9-]+( [a-z0-9-]+){0,3}") },
        "platform": { matches($0, "ios|android") },
        "device": { matches($0, "[0-9a-f]{16}") },
        "app": { value in (value as? String).map { DeviceAllowance.isAppID($0) && !$0.hasPrefix("-") } ?? false },
        "outcome": { value in AuditRecord.Outcome.allCases.contains { $0.rawValue == value as? String } },
        "exit": { isInteger($0, 0...255) },
        "reason": { value in (value as? String).flatMap(FailureReason.init(rawValue:)) != nil },
        "refusal": { value in (value as? String).map(AuditRecord.Shape.refusals.contains) ?? false },
        "testDevice": { isBool($0) },
        "managed": { isBool($0) },
        "ms": { isInteger($0, 0...86_400_000) },
        "expires": { matches($0, stampPattern) },
        "pins": { isInteger($0, 0...10_000) },
    ]

    static func expectPrivate(_ home: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let text = AuditFixtures.text(home) + AuditFixtures.text(home, rotated: true)
        #expect(!text.isEmpty, sourceLocation: sourceLocation)
        for canary in canaries {
            #expect(!text.contains(canary), "the trail holds \(canary)", sourceLocation: sourceLocation)
        }
        for object in try AuditFixtures.objects(home) + AuditFixtures.objects(home, rotated: true) {
            for (key, value) in object {
                let shape = try #require(shapes[key], "a record holds the unknown key \(key)", sourceLocation: sourceLocation)
                #expect(shape(value), "\(key) holds \(value)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test("the keys a record writes are the ones this suite knows a shape for")
    func keysAreKnown() {
        #expect(Set(AuditRecord.keys) == Set(Self.shapes.keys))
    }

    @Test("a record built from hostile input holds none of it", arguments: canaries)
    func hostileInputIsDropped(canary: String) throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let trail = AuditFixtures.trail(home: home, command: AuditTrail.command("type \(canary)"), version: canary)
        trail.record(AuditRecord.Outcome.allCases.map { AuditEvent($0, platform: .android, key: canary, app: canary, exit: 1, reason: canary, refusal: canary) })
        #expect(AuditFixtures.lines(home).count == AuditRecord.Outcome.allCases.count)
        try Self.expectPrivate(home)
    }

    @Test("only a path from the command tree is recorded as the command, never a word that failed to parse")
    func commandComesFromTheTree() {
        #expect(AuditTrail.command("app launch") == "app launch")
        #expect(AuditTrail.command("hunter2-typed-text") == nil && AuditTrail.command("type hunter2") == nil && AuditTrail.command(nil) == nil)
    }

    @Test("a session's name is the kernel's 16 characters, with anything outside letters, digits, dot, underscore and hyphen replaced")
    func sessionNameIsCut() {
        #expect(AuditRecord.Session(pid: 1, name: "Sign in to Example Bank").name == "Sign_in_to_Examp")
        #expect(AuditRecord.Session(pid: 1, name: "node").name == "node")
    }

    @Test("a refusal code this build has no name for is kept as `other`, and free text as nothing")
    func unknownRefusalIsOther() {
        let record = AuditRecord(AuditEvent(.refused, platform: .ios, key: "K", refusal: "managed_expired"), time: PolicyFixtures.now, version: "0.18.0", pid: 1, session: nil, command: "tap", milliseconds: nil)
        #expect(record.refusal == AuditRecord.Shape.other)
        let text = AuditRecord(AuditEvent(.refused, platform: .ios, key: "K", refusal: "Sign in to Example Bank"), time: PolicyFixtures.now, version: "0.18.0", pid: 1, session: nil, command: "tap", milliseconds: nil)
        #expect(text.refusal == nil)
    }

    @Test("every refusal the gate can give has a code the trail keeps")
    func refusalCodesAreKnown() {
        let refusals: [DeviceRefusal] = [
            .managedOff, .managedUnreadable("k"), .managedUnknownKey("k"), .managedNotListed, .notAllowed, .expired(PolicyFixtures.now), .listUnreadable("d"), .listChanged,
            .newerEntry("k"),
        ]
        for refusal in refusals {
            #expect(AuditRecord.Shape.refusals.contains(refusal.code), "\(refusal.code)")
        }
        #expect(AuditRecord.Shape.refusals.contains(SessionAudit.notNamed) && AuditRecord.Shape.refusals.contains(SessionAudit.notWired) && AuditRecord.Shape.refusals.contains(FailureReason.appNotAllowed.rawValue))
    }

    @Test("a line read back from the file is cut to the same shapes, since any process can write it")
    func parsedLinesAreShaped() throws {
        let line = """
        {"prev":"\(AuditTrail.genesis)","time":"2026-09-21T14:14:20Z","version":"Sign in to Example Bank","pid":1,"session":{"pid":2,"name":"A label with spaces"},\
        "command":"type --text hunter2-typed-text","platform":"android","device":"0123456789abcdef","app":"Balance $1,234.00","outcome":"ran","exit":0,\
        "reason":"Canary Phone of Sam","refusal":"A label with spaces","testDevice":false,"managed":false,"label":"Sign in to Example Bank"}
        """
        let record = try #require(AuditRecord.parse(Data(line.utf8))?.record)
        let again = record.line(prev: AuditTrail.genesis)
        for canary in Self.canaries { #expect(!again.contains(canary)) }
        #expect(record.command == "unknown" && record.version == "unknown" && record.app == nil && record.reason == nil && record.refusal == nil)
        #expect(record.session?.name == "A_label_with_spa")
        #expect(AuditRecord.parse(Data(line.replacingOccurrences(of: "0123456789abcdef", with: PolicyFixtures.serial).utf8)) == nil)
    }

    @Test("every hook writes only shaped fields: a failed command, a refusal, an access change and a session leave no label, value, text, name, id or argument")
    @MainActor
    func hooksWriteNoText() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let capture = AuditCapture()
        let trail = AuditFixtures.trail(home: home, command: "type", capture: capture)
        let entry = DeviceAllowance(
            platform: .android, key: PolicyFixtures.serial, name: "Canary Phone of Sam", added: PolicyFixtures.added, expires: PolicyFixtures.added.addingTimeInterval(3_600),
            apps: [AuditFixtures.playground]
        )
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home), audit: trail)
        try store.update { _ in DeviceAllowList(entries: [entry]) }

        let gate = DevicePolicyGate.fixed(PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry])), now: PolicyFixtures.now)
        try await DevicePolicyGate.$current.withValue(gate) {
            let scope = CommandScope()
            scope.audit.attach { trail }
            scope.configure(command: "type", namedApp: AuditFixtures.playground)
            scope.bannerNote = { _ in }
            scope.noteRoute(DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: []), device: DeviceID(rawValue: PolicyFixtures.serial, platform: .android), allowance: entry))
            await #expect(throws: CLIError.self) {
                try await scope.run {
                    throw CLIError(errorDescription: "The field \"Sign in to Example Bank\" kept hunter2-typed-text beside Balance $1,234.00 (--text /Volumes/canary/secret.txt).", reason: .inputFailed)
                }
            }

            let refused = CommandScope()
            refused.audit.attach { trail }
            refused.configure(command: "tap")
            #expect(throws: CLIError.self) {
                _ = try DeviceRouter.requireAllowed(platform: .ios, key: PolicyFixtures.phone, rawID: PolicyFixtures.phone, gate: gate, displayName: "Canary Phone of Sam", scope: refused)
            }
            await #expect(throws: CLIError.self) { try await refused.run { throw CLIError.deviceNotAllowed(name: "Canary Phone of Sam", key: PolicyFixtures.phone, refusal: .notAllowed) } }

            let named = CommandScope()
            named.audit.attach { trail }
            named.configure(command: "app launch", namedApp: "A label with spaces")
            named.bannerNote = { _ in }
            let route = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: []), device: DeviceID(rawValue: PolicyFixtures.serial, platform: .android), allowance: entry)
            #expect(throws: CLIError.self) { try DeviceRouter.requireNamedApp(named.namedApp, on: route, gate: gate, scope: named) }
            await #expect(throws: CLIError.self) { try await named.run { throw CLIError(errorDescription: "A label with spaces is not allowed.", reason: .appNotAllowed) } }
        }

        let broker = CommandAudit(trail: { trail })
        broker.write(AuditEvent(.sessionStarted, platform: .android, key: PolicyFixtures.serial, app: AuditFixtures.playground))
        broker.write(AuditEvent(.sessionStopped, platform: .android, key: PolicyFixtures.serial, refusal: DeviceRefusal.expired(PolicyFixtures.now).code))
        try store.update { _ in .empty }

        #expect(try AuditFixtures.outcomes(home) == ["allowed", "ran", "refused", "refused", "session_started", "session_stopped", "withdrawn"])
        #expect(capture.problems.isEmpty)
        try Self.expectPrivate(home)
    }
}
