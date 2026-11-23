import ArgumentParser
import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

/// A clock a test moves, read from any thread.
private final class MovingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

@Suite("Audit trail hooks")
@MainActor
struct AuditHookTests {
    static let pin = AuditFixtures.playground
    static let simulator = DevicePolicyRoutingTests.simulator

    static func phone(expires: Date? = PolicyFixtures.added.addingTimeInterval(3_600), apps: [String] = [pin], testDevice: Bool = false) -> DeviceAllowance {
        DeviceAllowance(platform: .android, key: PolicyFixtures.serial, name: "Test Phone", added: PolicyFixtures.added, expires: expires, apps: apps, testDevice: testDevice)
    }

    static func gate(_ entries: [DeviceAllowance], managed: ManagedDevicePolicy = .none, sealIntact: Bool = true, now: Date = PolicyFixtures.now) -> DevicePolicyGate {
        .fixed(PhysicalDevicePolicy(managed: managed, list: DeviceAllowList(entries: entries), sealIntact: sealIntact), now: now)
    }

    static func route(_ allowance: DeviceAllowance?) -> DeviceRouter.Route {
        let id = allowance.map { DeviceID(rawValue: $0.key, platform: $0.platform) } ?? DeviceID(rawValue: "emulator-5554", platform: .android)
        return DeviceRouter.Route(backend: FakeDeviceBackend(platform: id.platform, trees: []), device: id, allowance: allowance)
    }

    /// Runs `body` with a scope whose audit writes to a temporary home, then hands back each line as an object.
    static func recorded(
        command: String = "tap", namedApp: String? = nil, gate: DevicePolicyGate, capture: AuditCapture = AuditCapture(),
        _ body: (CommandScope, String) async throws -> Void
    ) async throws -> [[String: Any]] {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let trail = AuditFixtures.trail(home: home, command: command, capture: capture)
        let scope = CommandScope()
        scope.audit.attach { trail }
        scope.configure(command: command, namedApp: namedApp)
        scope.bannerNote = { _ in }
        try await DevicePolicyGate.$current.withValue(gate) { try await body(scope, home) }
        #expect(capture.problems.isEmpty)
        return try AuditFixtures.objects(home)
    }

    @Test("a command that succeeds on a phone leaves one `ran` record, however many times it routed")
    func successWritesOneRecord() async throws {
        let entry = Self.phone()
        let lines = try await Self.recorded(gate: Self.gate([entry])) { scope, _ in
            scope.noteRoute(Self.route(entry))
            scope.noteRoute(Self.route(entry))
            try await scope.run {}
        }
        #expect(lines.count == 1)
        #expect(lines[0]["outcome"] as? String == "ran" && lines[0]["exit"] as? Int == 0 && lines[0]["reason"] == nil && lines[0]["refusal"] == nil)
        #expect(lines[0]["app"] as? String == Self.pin && lines[0]["command"] as? String == "tap" && lines[0]["platform"] as? String == "android")
        #expect(lines[0]["testDevice"] as? Bool == false && lines[0]["managed"] as? Bool == false && lines[0]["ms"] as? Int == 12)
    }

    @Test("a command that fails leaves `ran` with its exit code and reason")
    func failureKeepsExitAndReason() async throws {
        let entry = Self.phone()
        let lines = try await Self.recorded(gate: Self.gate([entry])) { scope, _ in
            scope.noteRoute(Self.route(entry))
            await #expect(throws: CLIError.self) { try await scope.run { throw CLIError(errorDescription: "nothing changed", reason: .inputFailed) } }
        }
        #expect(lines.count == 1 && lines[0]["outcome"] as? String == "ran")
        #expect(lines[0]["exit"] as? Int == Int(FailureReason.inputFailed.exitCode.rawValue) && lines[0]["reason"] as? String == "input_failed")
    }

    @Test("a simulator or emulator command writes nothing, builds no trail and creates no folder")
    func virtualDevicesPayNothing() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gate = DevicePolicyGate(policy: {
            Issue.record("the policy was read for a virtual device")
            return PhysicalDevicePolicy(managed: .none, list: .empty)
        })
        try await DevicePolicyGate.$current.withValue(gate) {
            for failing in [false, true] {
                let scope = CommandScope()
                scope.audit.attach {
                    Issue.record("the audit trail was built for a virtual device")
                    return AuditFixtures.trail(home: home)
                }
                scope.configure(command: "tap")
                scope.noteRoute(Self.route(nil))
                scope.noteRoute(DeviceRouter.Route(backend: FakeDeviceBackend(trees: []), device: DeviceID(rawValue: Self.simulator, platform: .ios)))
                #expect(scope.audit.isEmpty)
                if failing {
                    await #expect(throws: CLIError.self) { try await scope.run { throw CLIError(errorDescription: "no", reason: .inputFailed) } }
                } else {
                    try await scope.run {}
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: home + "/.config"))
    }

    @Test("each refusal the gate gives is recorded as `refused` with its code", arguments: ["not_allowed", "expired", "managed_off", "managed_not_listed", "list_changed"])
    func gateRefusals(code: String) async throws {
        let gate: DevicePolicyGate
        switch code {
        case "expired": gate = Self.gate([Self.phone(expires: PolicyFixtures.added.addingTimeInterval(10))])
        case "managed_off": gate = Self.gate([Self.phone()], managed: ManagedDevicePolicy(allowPhysicalDevices: false))
        case "managed_not_listed": gate = Self.gate([Self.phone()], managed: ManagedDevicePolicy(allowedDeviceIDs: ["OTHER"]))
        case "list_changed": gate = Self.gate([Self.phone()], sealIntact: false)
        default: gate = Self.gate([])
        }
        let lines = try await Self.recorded(gate: gate) { scope, _ in
            let refusal = #expect(throws: CLIError.self) {
                _ = try DeviceRouter.requireAllowed(platform: .android, key: PolicyFixtures.serial, rawID: PolicyFixtures.serial, gate: gate, scope: scope)
            }
            await #expect(throws: CLIError.self) { try await scope.run { throw try #require(refusal) } }
        }
        #expect(lines.count == 1 && lines[0]["outcome"] as? String == "refused" && lines[0]["refusal"] as? String == code)
        #expect(lines[0]["exit"] as? Int == 7 && lines[0]["reason"] as? String == "device_not_allowed")
        #expect(lines[0]["managed"] as? Bool == code.hasPrefix("managed"))
    }

    @Test("an app outside the phone's pins is recorded as `refused` with the app it named")
    func appRefusal() async throws {
        let entry = Self.phone()
        let gate = Self.gate([entry])
        let lines = try await Self.recorded(command: "app launch", namedApp: "com.example.other", gate: gate) { scope, _ in
            let route = Self.route(entry)
            let refusal = #expect(throws: CLIError.self) { try DeviceRouter.requireNamedApp(scope.namedApp, on: route, gate: gate, scope: scope) }
            await #expect(throws: CLIError.self) { try await scope.run { throw try #require(refusal) } }
        }
        #expect(lines.count == 1 && lines[0]["outcome"] as? String == "refused" && lines[0]["refusal"] as? String == "app_not_allowed")
        #expect(lines[0]["app"] as? String == "com.example.other" && lines[0]["command"] as? String == "app launch")
    }

    @Test("a guarded control, a step that needs a person and an app refused after routing each read `refused`", arguments: [
        FailureReason.guardedControl, .personRequired, .appNotAllowed,
    ])
    func refusedAfterRouting(reason: FailureReason) async throws {
        let entry = Self.phone()
        let lines = try await Self.recorded(gate: Self.gate([entry])) { scope, _ in
            scope.noteRoute(Self.route(entry))
            await #expect(throws: CLIError.self) { try await scope.run { throw CLIError(errorDescription: "refused", reason: reason) } }
        }
        #expect(lines.count == 1 && lines[0]["outcome"] as? String == "refused" && lines[0]["reason"] as? String == reason.rawValue)
    }

    @Test("a test device and managed policy are flagged on the record")
    func flags() async throws {
        let entry = Self.phone(expires: nil, apps: [], testDevice: true)
        let lines = try await Self.recorded(gate: Self.gate([entry], managed: ManagedDevicePolicy(allowPhysicalDevices: true, allowTestDevices: true))) { scope, _ in
            scope.noteRoute(Self.route(entry))
            try await scope.run {}
        }
        #expect(lines[0]["testDevice"] as? Bool == true && lines[0]["managed"] as? Bool == true && lines[0]["app"] == nil)
    }

    @Test("the watchdog's exit writes the record at once, and the command's own end never writes it again")
    func timerFlushWritesOnce() async throws {
        let entry = Self.phone()
        let lines = try await Self.recorded(gate: Self.gate([entry])) { scope, _ in
            scope.noteRoute(Self.route(entry))
            await Task.detached { scope.audit.finish(exit: FailureReason.deviceUnresponsive.exitCode.rawValue, reason: FailureReason.deviceUnresponsive.rawValue) }.value
            try await scope.run {}
        }
        #expect(lines.count == 1 && lines[0]["reason"] as? String == "device_unresponsive")
        #expect(lines[0]["exit"] as? Int == Int(FailureReason.deviceUnresponsive.exitCode.rawValue))
    }

    @Test("a process that exits before the command's end still writes the record, without an exit code, and only once")
    func earlyExitWritesRecord() async throws {
        let entry = Self.phone()
        let lines = try await Self.recorded(command: "rn open", gate: Self.gate([entry])) { scope, _ in
            scope.noteRoute(Self.route(entry))
            scope.audit.finishEarly()
            scope.audit.finishEarly()
            try await scope.run {}
        }
        #expect(lines.count == 1 && lines[0]["outcome"] as? String == "ran" && lines[0]["exit"] == nil && lines[0]["command"] as? String == "rn open")
        let record = try #require(AuditRecord.parse(try JSONSerialization.data(withJSONObject: lines[0]))?.record)
        #expect(AuditScreen.result(record) == "ran, ended early")
    }

    @Test("unlock-code status and remove on an allowed, connected phone are recorded, since they read its label")
    func unlockCodeStatusIsRecorded() async throws {
        let entry = Self.phone()
        let gate = Self.gate([entry])
        let lines = try await Self.recorded(command: "unlock-code", gate: gate) { scope, _ in
            #expect(try await UnlockCodeCommand.gatePhone(entry.key, rawID: entry.key, action: .status, gate: gate, scope: scope, isListedPhone: { _ in true }))
            try await scope.run {}
        }
        #expect(lines.count == 1 && lines[0]["outcome"] as? String == "ran" && lines[0]["command"] as? String == "unlock-code")
        let unlisted = try await Self.recorded(command: "unlock-code", gate: gate) { scope, _ in
            #expect(try await UnlockCodeCommand.gatePhone(entry.key, rawID: entry.key, action: .status, gate: gate, scope: scope, isListedPhone: { _ in false }))
            try await scope.run {}
        }
        #expect(unlisted.isEmpty)
    }

    @Test("a registration and a saved unlock code name themselves in place of `ran`, and only for a device the gate allowed")
    func marks() async throws {
        let entry = Self.phone()
        let gate = Self.gate([entry])
        for outcome in [AuditRecord.Outcome.registration, .unlockCodeSaved] {
            let lines = try await Self.recorded(gate: gate) { scope, _ in
                scope.audit.mark(outcome, platform: .android, key: "NEVERSEEN")
                _ = try DeviceRouter.requireAllowed(platform: .android, key: PolicyFixtures.serial, rawID: PolicyFixtures.serial, gate: gate, scope: scope)
                scope.audit.mark(outcome, platform: .android, key: PolicyFixtures.serial)
                try await scope.run {}
            }
            #expect(lines.count == 1 && lines[0]["outcome"] as? String == outcome.rawValue && lines[0]["exit"] as? Int == 0)
        }
    }

    @Test("the allow-list store records each allowance written, changed, withdrawn or pruned after it expired, and nothing for one left alone")
    func storeEvents() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let clock = MovingClock(PolicyFixtures.now)
        let capture = AuditCapture()
        var trail = AuditFixtures.trail(home: home, command: "devices add", capture: capture)
        trail.now = { clock.now }
        trail.managed = { true }
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home), audit: trail)
        let phone = Self.phone()
        let tablet = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test iPad", added: PolicyFixtures.added, expires: nil, apps: [], testDevice: true)

        try store.update { _ in DeviceAllowList(entries: [phone, tablet]) }
        try store.update { $0.list }
        try store.update { $0.list.adding(Self.phone(apps: [Self.pin, "com.example.second"])) }
        #expect(throws: DeviceAllowListError.self) { try store.update { _ in throw DeviceAllowListError("stop") } }
        clock.advance(7_200)
        try store.update { $0.list.pruned(now: clock.now).removing(platform: .ios, key: PolicyFixtures.phone) }

        let lines = try AuditFixtures.objects(home)
        #expect(lines.map { $0["outcome"] as? String } == ["allowed", "allowed", "allowed", "withdrawn", "withdrawn"])
        #expect(lines[0]["expires"] as? String == "2026-09-21T15:13:20Z" && lines[0]["pins"] as? Int == 1 && lines[0]["app"] as? String == Self.pin)
        #expect(lines[1]["expires"] == nil && lines[1]["pins"] as? Int == 0 && lines[1]["testDevice"] as? Bool == true && lines[1]["platform"] as? String == "ios")
        #expect(lines[2]["pins"] as? Int == 2 && lines[2]["app"] == nil)
        let withdrawn = Dictionary(uniqueKeysWithValues: lines[3...].map { ($0["platform"] as? String ?? "", $0["refusal"] as? String) })
        #expect(withdrawn == ["android": "expired", "ios": nil])
        #expect(lines.allSatisfy { $0["managed"] as? Bool == true && $0["command"] as? String == "devices add" })
        #expect(trail.verify() == .intact(lines: 5))
    }

    @Test("the live stamp, with its session lookup, and one record together cost well under a millisecond")
    func liveStampCost() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let trail = AuditTrail(directory: UserConfigDirectory(home: home), stamp: { AuditTrail.liveStamp(command: "tap") })
        let event = AuditEvent(.ran, platform: .android, key: PolicyFixtures.serial, app: Self.pin, exit: 0)
        trail.record([event])
        var samples: [UInt64] = []
        for _ in 0..<200 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            trail.record([event])
            samples.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
        }
        let median = samples.sorted()[samples.count / 2]
        #expect(median < AuditFixtures.costBudget, "the median record took \(median / 1000) µs")
        let stamped = try #require(try AuditFixtures.objects(home).first)
        let version = stamped["version"] as? String
        #expect(version == VERSION || version == "unknown", "a build from a checkout with no tags has no version to record")
        #expect(stamped["pid"] as? Int == Int(getpid()))
        #expect(stamped["command"] as? String == "tap")
        #expect(AuditTrail.liveStamp(command: "typed words").command == nil)
    }

    @Test("the session is the owner a lease would record, found without walking past it")
    func sessionStopsAtOwner() {
        let lookups = AuditCapture()
        let names: [Int32: (String, Int32)] = [900: ("zsh", 800), 800: ("env", 700), 700: ("node", 600), 600: ("login", 500), 500: ("Terminal", 1)]
        let table = ProcessTable { pid in
            lookups.stamped()
            return names[pid].map { (ProcessIdentity(pid: pid, startTime: UInt64(pid), name: $0.0), $0.1) }
        }
        let session = AuditTrail.session(from: 900, in: table)
        #expect(session == AuditRecord.Session(pid: 700, name: "node") && lookups.stamps == 3)
        let owner = ProcessAncestry.owner(from: 900, in: table)
        #expect(owner?.pid == session?.pid && owner?.name == session?.name)
        #expect(AuditTrail.session(from: 1, in: table) == nil && AuditTrail.session(from: 4242, in: table) == nil)
        let shells = ProcessTable { pid in pid == 9 ? (ProcessIdentity(pid: 9, startTime: 1, name: "zsh"), 1) : nil }
        #expect(AuditTrail.session(from: 9, in: shells) == nil && ProcessAncestry.owner(from: 9, in: shells) == nil)
        let mine = ProcessTable.quick.lookup(getpid())
        let live = ProcessTable.live.lookup(getpid())
        #expect(mine?.identity == live?.identity && mine?.parent == live?.parent)
        #expect(ProcessTable.quick.lookup(1)?.identity.name == "launchd")
    }

    @Test("the store every command writes the allow-list through carries the audit trail")
    func liveStoreIsAudited() {
        #expect(DevicePolicySources.store().map { $0.audit != nil } ?? true)
    }

    @Test("stopping sessions records `session_stopped` for each iPhone, iPad or USB phone, and nothing for a simulator, an emulator or an AVD's name")
    func sessionStop() async throws {
        let lines = try await Self.recorded(command: "session stop", gate: Self.gate([Self.phone()])) { scope, _ in
            SessionAudit.noteStopped(
                [PolicyFixtures.serial, PolicyFixtures.phone.lowercased(), PolicyFixtures.phone, Self.simulator, "emulator-5554", "Offsider_E2E"], gate: .current, audit: scope.audit,
                isDefinedAVD: { $0 == "Offsider_E2E" }
            )
            try await scope.run {}
        }
        #expect(lines.count == 2 && lines.allSatisfy { $0["outcome"] as? String == "session_stopped" && $0["command"] as? String == "session stop" })
        #expect(Set(lines.compactMap { $0["device"] as? String }) == [
            AuditRecord.deviceKey(platform: .android, key: PolicyFixtures.serial), AuditRecord.deviceKey(platform: .ios, key: PolicyFixtures.phone),
        ])
    }

    @Test("a broker records its start at once and its stop when it ends, with the refusal that ended it")
    func brokerStartAndLapse() async throws {
        let entry = Self.phone()
        let clock = MovingClock(PolicyFixtures.now)
        let policy = PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry]))
        let fresh = DevicePolicyGate(policy: { policy }, now: { clock.now })
        var started = 0
        let lines = try await Self.recorded(command: "android-session serve", gate: Self.gate([entry])) { scope, home in
            SessionAudit.noteBroker(entry, policy: policy, audit: scope.audit)
            started = AuditFixtures.lines(home).count
            #expect(SessionAudit.noteLapse(platform: .android, key: entry.key, gate: fresh, audit: scope.audit) == nil)
            clock.advance(7_200)
            #expect(SessionAudit.noteLapse(platform: .android, key: entry.key, gate: fresh, audit: scope.audit)?.code == "expired")
            try await scope.run {}
        }
        #expect(started == 1)
        #expect(lines.map { $0["outcome"] as? String } == ["session_started", "session_stopped"])
        #expect(lines[0]["refusal"] == nil && lines[1]["refusal"] as? String == "expired" && lines[1]["exit"] as? Int == 0)
    }

    @Test("a phone's warm helper is stopped at the first recheck that finds its allowance lapsed, and never while it holds")
    func warmHelperRecheck() async throws {
        let entry = Self.phone()
        let clock = MovingClock(PolicyFixtures.now)
        let policy = PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry]))
        let fresh = DevicePolicyGate(policy: { policy }, now: { clock.now })
        var stops: [String] = []
        let waits = AuditCapture()
        let lines = try await Self.recorded(command: "android-session serve", gate: Self.gate([entry])) { scope, _ in
            SessionAudit.noteBroker(entry, policy: policy, audit: scope.audit)
            await AndroidSessionServe.watchAllowance(serial: entry.key, gate: fresh, audit: scope.audit, sleep: { interval in
                #expect(interval == .seconds(30))
                waits.stamped()
                if waits.stamps == 3 { clock.advance(7_200) }
            }, stop: { stops.append($0) })
            try await scope.run {}
        }
        #expect(waits.stamps == 3 && stops == ["expired"])
        #expect(lines.last?["outcome"] as? String == "session_stopped" && lines.last?["refusal"] as? String == "expired")
    }

    @Test("doctor on a physical device is recorded as allowed or refused before any probe")
    func doctorNotes() async throws {
        let entry = Self.phone()
        let gate = Self.gate([entry])
        let allowed = try await Self.recorded(command: "doctor", gate: gate) { scope, _ in
            Doctor.noteAudit(DoctorPolicy(platform: .android, key: entry.key, decision: .allowed(entry), managed: false), target: (.android, entry.key), gate: gate, audit: scope.audit)
            try await scope.run {}
        }
        #expect(allowed.count == 1 && allowed[0]["outcome"] as? String == "ran" && allowed[0]["command"] as? String == "doctor")
        let refused = try await Self.recorded(command: "doctor", gate: Self.gate([])) { scope, _ in
            Doctor.noteAudit(DoctorPolicy(platform: .android, key: entry.key, decision: .refused(.notAllowed), managed: false), target: (.android, entry.key), gate: Self.gate([]), audit: scope.audit)
            await #expect(throws: ExitCode.self) { try await scope.run { throw ExitCode(1) } }
        }
        #expect(refused.count == 1 && refused[0]["outcome"] as? String == "refused" && refused[0]["refusal"] as? String == "not_allowed")
        let unnamed = try await Self.recorded(command: "doctor", gate: gate) { scope, _ in
            Doctor.noteAudit(
                DoctorPolicy(platform: .android, key: entry.key, decision: .refused(.notAllowed), managed: false), target: (.android, entry.key), fromEnvironment: true, gate: gate,
                audit: scope.audit
            )
            await #expect(throws: ExitCode.self) { try await scope.run { throw ExitCode(4) } }
        }
        #expect(unnamed.count == 1 && unnamed[0]["refusal"] as? String == SessionAudit.notNamed)
    }
}

@Suite("Audit coverage of the command tree")
struct AuditCoverageTests {
    private static let commands = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Offsider/Commands")

    @Test("every command says how its use of a physical device reaches the audit trail")
    func everyCommandClassified() {
        let paths = Set(CommandPath.all())
        #expect(paths == Set(AuditCoverage.table.keys), "unclassified: \(paths.symmetricDifference(AuditCoverage.table.keys).sorted())")
    }

    @Test("a command file that asks the gate about a device without routing it records to the audit trail, or is listed as read-only")
    func directGateUsersRecord() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.commands, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 40)
        var direct: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let asksGate = ["DevicePolicyGate", "requireAllowed(", ".decision(platform"].contains { text.contains($0) }
            let routes = ["DeviceRouter.route", "DeviceRouter.Route", "routeForInput"].contains { text.contains($0) }
            guard asksGate, !routes else { continue }
            direct.insert(file.lastPathComponent)
            let records = text.contains("CommandScope.current.audit") || text.contains("SessionAudit.")
            #expect(records || AuditCoverage.readOnlyFiles.contains(file.lastPathComponent), "\(file.lastPathComponent) reads the device gate and leaves no audit record")
        }
        #expect(direct.count >= 5 && AuditCoverage.readOnlyFiles.isSubset(of: direct))
    }

    @Test("the commands that note their own records are the ones whose files do")
    func ownCommandsRecord() throws {
        let files = ["doctor": "Doctor.swift", "unlock-code": "UnlockCode.swift", "runner stop": "Runner.swift", "session stop": "Session.swift",
                     "device-session serve": "DeviceSession.swift", "android-session serve": "AndroidSession.swift"]
        for (command, file) in files {
            #expect(AuditCoverage.table[command] == .own, "\(command)")
            let text = try String(contentsOf: Self.commands.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains("audit"), "\(file) no longer records \(command)")
        }
        #expect(AuditCoverage.table.filter { $0.value == .own }.keys.sorted() == (Array(files.keys) + ["devices add", "devices remove"]).sorted())
    }
}

@Suite("devices status --audit")
@MainActor
struct DeviceAuditCommandTests {
    static func context(home: String, trail: AuditTrail, entries: [DeviceAllowance]) throws -> DeviceAccessContext {
        let seal = MemorySeal()
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home), audit: trail)
        try store.update({ _ in DeviceAllowList(entries: entries) }, commit: { try seal.seal($0) })
        var context = DeviceAccessCommandTests.context(home: home, seal: seal)
        context.store = { store }
        return context
    }

    @Test("--last needs --audit and takes 1 to 1000")
    func lastIsValidated() {
        #expect(throws: (any Error).self) { try DeviceAccessStatus.parse(["--last", "5"]) }
        #expect(throws: (any Error).self) { try DeviceAccessStatus.parse(["--audit", "--last", "0"]) }
        #expect(throws: (any Error).self) { try DeviceAccessStatus.parse(["--audit", "--last", "1001"]) }
        #expect((try? DeviceAccessStatus.parse(["--audit", "--last", "1000"])) != nil)
    }

    @Test("the newest records print as plain columns for an agent and name the device for a person")
    func showsRecords() throws {
        try AuditTrailTests.withHome { home in
            let trail = AuditFixtures.trail(home: home, command: "tap")
            let entry = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: [AuditFixtures.playground])
            let context = try Self.context(home: home, trail: trail, entries: [entry])
            trail.record([
                AuditEvent(.ran, platform: .android, key: PolicyFixtures.serial, app: AuditFixtures.playground, exit: 0),
                AuditEvent(.refused, platform: .ios, key: PolicyFixtures.phone, exit: 7, reason: "device_not_allowed", refusal: "not_allowed"),
            ])
            let all = try DeviceAccessStatus.parse(["--audit"]).auditRecords(context: context)
            #expect(all.records.map(\.outcome) == [.allowed, .ran, .refused] && all.path == AuditFixtures.path(home))
            #expect(try DeviceAccessStatus.parse(["--audit", "--last", "1"]).auditRecords(context: context).records.map(\.outcome) == [.refused])
            #expect(try DeviceAccessStatus.parse(["--audit", "--device", PolicyFixtures.serial]).auditRecords(context: context).records.map(\.outcome) == [.allowed, .ran])

            let page = AuditScreen.page(all.records, list: DeviceAllowList(entries: [entry]), path: all.path, timeZone: TimeZone(identifier: "UTC")!)
            let agent = AgentRenderer.body(page.blocks)
            let phone = AuditRecord.deviceKey(platform: .android, key: PolicyFixtures.serial)
            #expect(agent.contains("TIME                  DEVICE            PLATFORM  COMMAND  OUTCOME  EXIT  REASON              REFUSAL      APP"))
            #expect(agent.contains("2026-09-21T14:14:20Z  \(phone)  android   tap      ran      0     -                   -            \(AuditFixtures.playground)"))
            #expect(agent.contains("refused  7     device_not_allowed  not_allowed  -"))
            #expect(!agent.contains(PolicyFixtures.serial) && !agent.contains("Test iPhone"))
            let person = PersonRenderer.body(page.blocks, canvas: Canvas(columns: 100, style: .plain))
            #expect(person.contains(AuditScreen.title) && person.contains("Test iPhone") && person.contains("2026-09-21 14:14") && person.contains("refused, not_allowed"))
            #expect(!person.contains(phone))
        }
    }

    @Test("--json adds the records as `audit`, without their chain links")
    func jsonAddsAudit() throws {
        try AuditTrailTests.withHome { home in
            let trail = AuditFixtures.trail(home: home)
            let context = try Self.context(home: home, trail: trail, entries: [PolicyFixtures.entry(.android, key: PolicyFixtures.serial)])
            let records = try DeviceAccessStatus.parse(["--audit", "--json"]).auditRecords(context: context).records
            let text = context.policy().statusJSON(now: PolicyFixtures.now, audit: records)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let audit = try #require(object["audit"] as? [[String: Any]])
            #expect(audit.count == 1 && audit[0]["outcome"] as? String == "allowed" && audit[0]["prev"] == nil)
            #expect(object["version"] as? Int == 1 && (object["devices"] as? [Any])?.count == 1)
            let plain = try #require(try JSONSerialization.jsonObject(with: Data(context.policy().statusJSON(now: PolicyFixtures.now).utf8)) as? [String: Any])
            #expect(plain["audit"] == nil)
        }
    }

    @Test("an empty trail says so")
    func emptyTrail() {
        let page = AuditScreen.page([], list: .empty, path: "~/.config/offsider/device-audit.log", timeZone: .gmt)
        #expect(AgentRenderer.body(page.blocks) == "Audit trail: ~/.config/offsider/device-audit.log holds no records.\n")
        #expect(PersonRenderer.body(page.blocks, canvas: Canvas(columns: 80, style: .plain)).contains(AuditScreen.nothing))
    }
}
