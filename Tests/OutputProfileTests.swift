import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

/// Runs a test or suite as if standard output were a terminal (`.person`) or a pipe (`.agent`), whatever `swift test` writes to.
struct OutputProfileTrait: TestTrait, SuiteTrait, TestScoping {
    let profile: OutputProfile
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await OutputProfile.$override.withValue(profile) { try await function() }
    }
}

extension Trait where Self == OutputProfileTrait {
    /// Today's behaviour for a person at a terminal: bare clean names, `--no-mask-secure` allowed.
    static var personOutput: Self { OutputProfileTrait(profile: .person) }
    static var agentOutput: Self { OutputProfileTrait(profile: .agent) }
}

/// The values at `path` (`devices[].name`, `error.message`, `roots[].children[]**.label`) in a parsed JSON document; empty when the path names nothing.
func untrustedValues(_ path: String, in object: Any) -> [Any] {
    var values: [Any] = [object]
    for segment in path.split(separator: ".") {
        if segment.hasSuffix("[]**") {
            let name = String(segment.dropLast(4))
            var all: [Any] = []
            var pending = values
            while let next = pending.popLast() {
                all.append(next)
                pending += ((next as? [String: Any])?[name] as? [Any]) ?? []
            }
            values = all
            continue
        }
        let isArray = segment.hasSuffix("[]")
        let name = isArray ? String(segment.dropLast(2)) : String(segment)
        values = values.compactMap { ($0 as? [String: Any])?[name] }.filter { !($0 is NSNull) }
        if isArray { values = values.flatMap { ($0 as? [Any]) ?? [] } }
    }
    return values
}

/// The document's `untrusted` list, each path checked to name at least one value.
func expectUntrustedPathsResolve(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], sourceLocation: sourceLocation)
    let paths = try #require(object[UntrustedPaths.key] as? [String], sourceLocation: sourceLocation)
    #expect(!paths.isEmpty, sourceLocation: sourceLocation)
    for path in paths {
        #expect(!untrustedValues(path, in: object).isEmpty, "\(path) names nothing", sourceLocation: sourceLocation)
    }
    return paths
}

@Suite("Output profile")
struct OutputProfileTests {
    @Test("a terminal is a person, a pipe is an agent, and OFFSIDER_OUTPUT overrides either; an unknown value is ignored")
    func resolve() {
        #expect(OutputProfile.resolve(environment: [:], isTerminal: true) == .person)
        #expect(OutputProfile.resolve(environment: [:], isTerminal: false) == .agent)
        #expect(OutputProfile.resolve(environment: ["OFFSIDER_OUTPUT": "person"], isTerminal: false) == .person)
        #expect(OutputProfile.resolve(environment: ["OFFSIDER_OUTPUT": " Agent "], isTerminal: true) == .agent)
        #expect(OutputProfile.resolve(environment: ["OFFSIDER_OUTPUT": "human"], isTerminal: false) == .agent)
    }

    @Test("a person sees a clean name bare, an agent always sees it quoted, and a hazard is quoted for both")
    func field() {
        #expect(TerminalText.field("Sign in", profile: .person) == "Sign in")
        #expect(TerminalText.field("Sign in", profile: .agent) == #""Sign in""#)
        #expect(TerminalText.field("a\u{1B}]52;c;x\u{07}", profile: .person) == #""a\u001b]52;c;x\u0007""#)
    }

    @Test("the untrusted list goes after every other key, pretty or compact, and an empty list adds nothing")
    func appending() throws {
        #expect(UntrustedPaths.appending(["devices[].name"], to: #"{"a":1}"#) == #"{"a":1,"untrusted":["devices[].name"]}"#)
        #expect(UntrustedPaths.appending(["x"], to: "{}") == #"{"untrusted":["x"]}"#)
        #expect(UntrustedPaths.appending([], to: #"{"a":1}"#) == #"{"a":1}"#)
        let pretty = UntrustedPaths.appending(["devices[].name", "details"], to: "{\n  \"a\": 1\n}\n")
        #expect(pretty == "{\n  \"a\": 1,\n  \"untrusted\": [\"devices[].name\", \"details\"]\n}\n")
        let encoder = UntrustedPaths.appending(["b"], to: "{\n  \"a\" : 1\n}")
        #expect(encoder == "{\n  \"a\" : 1,\n  \"untrusted\" : [\"b\"]\n}")
        _ = try JSONSerialization.jsonObject(with: Data(encoder.utf8))
    }

    @Test("an agent cannot read --raw-source; a person can")
    func rawSourceRefused() throws {
        let refused = #expect(throws: CLIError.self) { try DescribeUI.refuseRawSourceForAgent(profile: .agent) }
        #expect(refused?.reason == .personRequired)
        try DescribeUI.refuseRawSourceForAgent(profile: .person)
    }

    @Test("--raw-source refuses a tree past the caps and escapes every hazard it prints")
    func rawSourceCaps() throws {
        let deep = Data((String(repeating: "[", count: JSONShape.maxDepth + 1) + String(repeating: "]", count: JSONShape.maxDepth + 1)).utf8)
        #expect(JSONShape.refusal(deep) != nil)
        let many = Data(("[" + Array(repeating: "{}", count: JSONShape.maxObjects + 1).joined(separator: ",") + "]").utf8)
        #expect(JSONShape.refusal(many) != nil)
        #expect(JSONShape.refusal(Data(#"{"a":"[[[[{{{{"}"#.utf8), maxDepth: 2) == nil)
        #expect(throws: CLIError.self) { try DescribeUI.rawSourceText(deep) }

        let raw = Data("{\"label\":\"Pay\u{202E}\u{E0041}\u{7F}\"}".utf8)
        #expect(try DescribeUI.rawSourceText(raw) == #"{"label":"Pay\u202e\udb40\udc41\u007f"}"#)
    }
}

@Suite("Unmasked capture consent", .serialized)
struct UnmaskedConsentTests {
    @Test("an agent's --no-mask-secure is refused without a terminal, asks a person on one, and a person at a terminal is never asked")
    func consent() async throws {
        UnmaskedConsent.confirmed = false
        defer { UnmaskedConsent.confirmed = false }
        let refused = #expect(throws: CLIError.self) { try UnmaskedConsent.require(profile: .agent) }
        #expect(refused?.reason == .personRequired)
        #expect(refused?.failureMessage.contains("Run it from your own terminal") == true)

        let nobody = FakePresence()
        let piped = await #expect(throws: CLIError.self) {
            try await PersonPresence.$terminal.withValue({ false }) {
                try await PersonPresence.$current.withValue(nobody) { try await UnmaskedConsent.confirm(command: "screenshot", profile: .agent) }
            }
        }
        #expect(piped?.reason == .personRequired)
        #expect(nobody.reasons.isEmpty)

        let declined = FakePresence(failure: PersonPresence.error(for: .notInteractive))
        await #expect(throws: CLIError.self) {
            try await PersonPresence.$terminal.withValue({ true }) {
                try await PersonPresence.$current.withValue(declined) { try await UnmaskedConsent.confirm(command: "screenshot", profile: .agent) }
            }
        }
        #expect(!UnmaskedConsent.confirmed)

        let person = FakePresence()
        try await PersonPresence.$terminal.withValue({ true }) {
            try await PersonPresence.$current.withValue(person) { try await UnmaskedConsent.confirm(command: "screenshot", profile: .agent) }
        }
        #expect(person.reasons == ["screenshot with password fields unmasked"])
        try UnmaskedConsent.require(profile: .agent)

        UnmaskedConsent.confirmed = false
        let unasked = FakePresence()
        try await PersonPresence.$current.withValue(unasked) { try await UnmaskedConsent.confirm(command: "batch", profile: .person) }
        try UnmaskedConsent.require(profile: .person)
        #expect(unasked.reasons.isEmpty)
    }

    @Test("for an agent, a screenshot step's --no-mask-secure and OFFSIDER_MASK_SECURE=0 are refused before any capture")
    func screenshotPlan() throws {
        UnmaskedConsent.confirmed = false
        try OutputProfile.$override.withValue(.agent) {
            let unmasked = try Screenshot.parse(["--no-mask-secure", "--device", "emulator-5554"])
            #expect(throws: CLIError.self) { try unmasked.maskPlan() }
            let plain = try Screenshot.parse(["--device", "emulator-5554"])
            #expect(throws: CLIError.self) { try plain.maskPlan(environment: ["OFFSIDER_MASK_SECURE": "0"]) }
            #expect(try plain.maskPlan().secure)
            #expect(try !unmasked.maskPlan(gated: false).secure)
        }
    }
}

/// One hostile label: an OSC 52 clipboard write, a right-to-left override and a tag-block payload.
private let hostile = "Pay\u{1B}]52;c;ZXZpbA==\u{07} now\u{202E}lmth.exe\u{E0049}\u{E0047}\u{E004E}"

/// True when `text` holds a raw control (other than newline and tab), bidi, invisible or tag character.
private func holdsHazard(_ text: String) -> Bool {
    var previous: Unicode.Scalar?
    for scalar in text.unicodeScalars {
        defer { previous = scalar }
        if scalar == "\n" || scalar == "\t" { continue }
        if TerminalText.isHazard(scalar, after: previous) { return true }
    }
    return false
}

@Suite("Untrusted text sinks", .personOutput)
struct UntrustedSinkTests {
    static func device(_ name: String) -> DeviceSummary {
        DeviceSummary(id: "00008130-000000000000FAKE", platform: .ios, state: "Untrusted", name: name, osVersion: "27.0", deviceType: name, kind: .physical, connection: "usb")
    }

    static func doctorReport(_ text: String) -> DoctorReport {
        DoctorReport(
            offsiderVersion: "0.13.0", udid: nil, device: DoctorDevice(id: "emulator-5554", platform: "android", name: text, kind: "emulator"),
            xcode: XcodeSummary(developerDir: nil, version: "27.0", build: nil, coreSimulator: nil),
            booted: [BootedSimulator(udid: "00000000-0000-4000-8000-000000000001", name: text, osVersion: "27.0", deviceType: "iPhone")],
            checks: [DoctorCheckResult(id: DoctorCheckID.allCases[0], status: .warn, detail: "adb said: \(text)")]
        )
    }

    @MainActor
    static func sinks(_ label: String) throws -> [(String, String)] {
        let payload = ErrorPayload(
            reason: .selectorNotFound, message: "No element matched. Did you mean \(TerminalText.quoted(label))?",
            candidates: [FailureCandidate(id: label, label: label, role: "button", frame: nil, onScreen: true)]
        )
        return [
            ("list-devices table", DeviceListRenderer.table([device(label)])),
            ("list-devices table, agent", DeviceListRenderer.table([device(label)], profile: .agent)),
            ("list-devices --json", DeviceListRenderer.json([device(label)])),
            ("list-devices hints", ListDevices.phoneHints([device(label)]).joined(separator: "\n")),
            ("doctor --json", try Doctor.jsonText(doctorReport(label))),
            ("describe-ui --raw-source", try DescribeUI.rawSourceText(Data("{\"label\":\"\(label.replacingOccurrences(of: "\u{1B}", with: "\\u001b").replacingOccurrences(of: "\u{07}", with: "\\u0007"))\u{202E}\u{E0041}\"}".utf8))),
            ("Error line", ErrorReporter.errorText(payload.message)),
            ("error envelope", ErrorReporter.envelopeLine(payload, command: "tap")),
            ("cover", TapCover.describe(CoverVerdict(cover: FakeUI.node(.button, id: label, label: label, frame: UIFrame(x: 0, y: 0, width: 10, height: 10)), evidence: .hitTest, isConfident: true, screen: label))),
            ("logs --raw", LogText.format(LogEntry(timestamp: Date(timeIntervalSince1970: 0), level: "info", process: label, message: label), timeZone: TimeZone(identifier: "UTC")!, keepsColour: true)),
            ("TerminalText.field", TerminalText.field(label, profile: .agent)),
            ("TerminalText.line", TerminalText.line(label)),
        ]
    }

    @Test("an OSC 52 write, a bidi override and a tag payload reach no sink raw")
    @MainActor
    func noRawHazards() throws {
        for (name, output) in try Self.sinks(hostile) {
            #expect(!holdsHazard(output), "\(name) printed a raw hazard: \(output.debugDescription)")
        }
    }

    @Test("the new blank-looking fillers print as escapes, and an emoji's lone presentation selector does not", arguments: [
        "\u{034F}", "\u{115F}", "\u{1160}", "\u{17B4}", "\u{17B5}", "\u{180B}", "\u{180C}", "\u{180D}", "\u{3164}", "\u{FFA0}", "\u{2800}",
    ])
    func fillers(filler: String) {
        let shown = TerminalText.line("a\(filler)b")
        #expect(shown.hasPrefix("a\\u"))
        #expect(!holdsHazard(shown))
        #expect(TerminalText.line("❤\u{FE0F}") == "❤\u{FE0F}")
    }

    @Test("logs --raw keeps colour and drops conceal, also inside a combined SGR, but never a colour argument of 8")
    func conceal() {
        #expect(TerminalText.line("\u{1B}[31mred\u{1B}[0m", keepsSGR: true) == "\u{1B}[31mred\u{1B}[0m")
        #expect(TerminalText.line("a\u{1B}[8mhidden\u{1B}[28m", keepsSGR: true) == "ahidden\u{1B}[28m")
        #expect(TerminalText.line("\u{1B}[1;8;31mx", keepsSGR: true) == "\u{1B}[1;31mx")
        #expect(TerminalText.line("\u{1B}[08mx", keepsSGR: true) == "x")
        #expect(TerminalText.line("\u{1B}[38;5;8mgrey", keepsSGR: true) == "\u{1B}[38;5;8mgrey")
        #expect(TerminalText.line("\u{1B}[48;2;8;8;8;8mx", keepsSGR: true) == "\u{1B}[48;2;8;8;8mx")
    }

    @Test("an error block shows at most 4 KiB, on stderr and in the envelope, and says how much it left out")
    func errorCap() throws {
        let long = String(repeating: "adb FAIL ", count: 2_000)
        let text = ErrorReporter.errorText(long)
        #expect(text.count < TerminalText.maxErrorCharacters + 40)
        #expect(text.contains("…(+"))
        let envelope = ErrorReporter.envelopeLine(ErrorPayload(reason: .commandFailed, message: long).scrubbed {
            TerminalText.capped($0, cap: TerminalText.maxErrorCharacters)
        }, command: "tap")
        #expect(envelope.count < TerminalText.maxErrorCharacters + 300)
    }

    @Test("each command's untrusted paths name values in a sample document", arguments: ["list-devices", "doctor", "error envelope", "error envelope with candidates"])
    @MainActor
    func untrustedPathsResolve(command: String) throws {
        switch command {
        case "list-devices":
            #expect(try expectUntrustedPathsResolve(DeviceListRenderer.json([Self.device("Ada's iPhone")])) == ["devices[].name", "devices[].osVersion", "devices[].deviceType"])
        case "doctor":
            #expect(try expectUntrustedPathsResolve(try Doctor.jsonText(Self.doctorReport("Pixel"))) == ["checks[].detail", "device.name", "booted[].name"])
        case "error envelope":
            #expect(try expectUntrustedPathsResolve(ErrorReporter.envelopeLine(ErrorPayload(reason: .commandFailed, message: "adb: closed"), command: "tap")) == ["error.message"])
        default:
            let payload = ErrorPayload(
                reason: .selectorNotFound, message: "No element matched.",
                candidates: [FailureCandidate(id: "save", label: "Save", role: "button", frame: nil, onScreen: true, window: "Main", screen: "home")]
            )
            #expect(try expectUntrustedPathsResolve(ErrorReporter.envelopeLine(payload, command: "tap")).count == 5)
        }
    }

    static let tree = UITree(platform: .ios, device: "fake-device", roots: [
        FakeUI.node(.application, label: "Playground", children: [
            FakeUI.node(.group, children: [FakeUI.node(.button, id: "save", label: "Save", value: "on")]),
        ]),
    ])

    static let nearMiss = FailureCandidate(id: "sign-in", label: "Sign in", role: "button", frame: nil, onScreen: true, window: "Main", screen: "home")

    static func describe(_ options: UITreeRenderOptions) -> String {
        String(decoding: UITreeRenderer.render(tree, options, marksUntrusted: true), as: UTF8.self)
    }

    @Test("each tree, verify, batch, logs and wait document names the app's text it holds", arguments: [
        "describe-ui --json", "describe-ui --flat", "describe-ui --format ndjson", "tap --verify --json",
        "batch describe-ui step", "batch wait step", "logs --json", "logs --follow --json", "wait --json",
    ])
    func moreUntrustedPathsResolve(command: String) throws {
        let node = UntrustedPaths.under("roots[].children[]**", ["id", "label", "value"])
        switch command {
        case "describe-ui --json":
            #expect(try expectUntrustedPathsResolve(Self.describe(UITreeRenderOptions())) == node)
        case "describe-ui --flat":
            #expect(try expectUntrustedPathsResolve(Self.describe(UITreeRenderOptions(flat: true))) == ["nodes[].id", "nodes[].label", "nodes[].value"])
        case "describe-ui --format ndjson":
            let lines = Self.describe(UITreeRenderOptions(format: .ndjson)).split(separator: "\n").map(String.init)
            #expect(!lines[0].contains(UntrustedPaths.key))
            #expect(try expectUntrustedPathsResolve(lines[1]) == ["label"])
            #expect(try expectUntrustedPathsResolve(lines[3]) == ["id", "label", "value"])
        case "tap --verify --json":
            let report = VerifyReport(
                command: "tap", target: "--id save", dispatched: .yes, verified: true, attempts: 1, change: .accessibilityTree,
                changes: [VerifyChange(kind: .changed, node: #"button "Save" id=save"#, field: "value", old: "off", new: "on")]
            )
            #expect(try expectUntrustedPathsResolve(String(decoding: try report.jsonData(), as: UTF8.self)) == ["changes[].node", "changes[].old", "changes[].new"])
        case "batch describe-ui step":
            let record = BatchStepRecord(step: 1, kind: "describe-ui", line: "describe-ui", elapsed: 0, failure: nil, detail: .describe(Self.tree, UITreeRenderOptions()))
            #expect(try expectUntrustedPathsResolve(record.jsonLine()) == UntrustedPaths.under("tree", node))
            let text = BatchStepRecord(step: 1, kind: "describe-ui", line: "describe-ui", elapsed: 0, failure: nil, detail: .describe(Self.tree, .summary))
            #expect(try expectUntrustedPathsResolve(text.jsonLine()) == ["output"])
        case "batch wait step":
            var outcome = WaitOutcome(met: false, elapsed: 1, reason: "not found")
            outcome.nearMiss = WaitNearMiss(summary: "", candidates: [Self.nearMiss])
            let failure = BatchStepRecord.Failure(error: ErrorPayload(reason: .conditionNotMet, message: "Timed out."))
            let record = BatchStepRecord(step: 2, kind: "wait", line: "wait --label 'Sign In'", elapsed: 1, failure: failure, detail: .wait(outcome))
            #expect(try expectUntrustedPathsResolve(record.jsonLine()) == ["error.message"] + UntrustedPaths.under("nearest[]", UntrustedPaths.candidateFields))
        case "logs --json":
            let report = LogReport(platform: .android, device: "emulator-5554", entries: [LogEntry(process: "com.example", tag: "Auth", message: "signed in")], truncated: 0)
            #expect(try expectUntrustedPathsResolve(report.jsonLine()) == ["entries[].process", "entries[].tag", "entries[].message"])
            #expect(!LogReport(platform: .android, device: "emulator-5554", entries: [], truncated: 0).jsonLine().contains(UntrustedPaths.key))
        case "logs --follow --json":
            #expect(try expectUntrustedPathsResolve(LogReport.jsonLine(LogEntry(message: "ready"))) == ["message"])
        default:
            let met = WaitOutcome(met: true, elapsed: 0.2, reason: "on screen", match: FakeUI.node(.button, id: "save", label: "Save"))
            #expect(try expectUntrustedPathsResolve(WaitReport(met).jsonLine()) == ["match.id", "match.label"])
            #expect(!WaitReport(WaitOutcome(met: true, elapsed: 1, reason: "waited")).jsonLine().contains(UntrustedPaths.key))
        }
    }

    @Test("an empty device list carries no untrusted list, so its shape is unchanged")
    func emptyList() {
        #expect(!DeviceListRenderer.json([]).contains(UntrustedPaths.key))
    }
}
