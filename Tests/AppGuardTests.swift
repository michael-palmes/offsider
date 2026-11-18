import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// What a person at the Mac was asked, and what they answer.
private final class Asks: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    let approves: Bool

    init(approves: Bool) {
        self.approves = approves
    }

    var reasons: [String] { lock.withLock { asked } }

    func ask(_ reason: String) throws {
        lock.withLock { asked.append(reason) }
        if !approves { throw CLIError.personRequired("declined") }
    }
}

@MainActor
@Suite("The app guard in front of input")
struct AppGuardTests {
    static let app = "com.mpalmes.offsider.playground"
    static let device = DeviceID(rawValue: "recording", platform: .ios)
    static let order = GuardRule(name: "Place an order", action: .ask, control: GuardMatcher(id: "order-confirm"))
    static let password = GuardRule(name: "Password", action: .never, control: GuardMatcher(label: "Change password"))

    static let screen = FakeUI.tree([
        FakeUI.node(.button, id: "order-confirm", label: "Buy now", frame: FakeUI.frame(20, 600, 200, 44)),
        FakeUI.node(.button, label: "Change password", frame: FakeUI.frame(20, 700, 200, 44)),
        FakeUI.node(.button, id: "details", label: "Details", frame: FakeUI.frame(20, 300, 200, 44)),
    ])

    static func rules(_ rules: [GuardRule] = [order, password], askUsers: [String]? = nil, sealIntact: Bool = true) -> GuardSources.Loaded {
        var loaded = GuardSources.Loaded()
        loaded.approvals = GuardApprovals().approving(GuardConfig(apps: [app], rules: rules, askUsers: askUsers), source: nil, now: Date(timeIntervalSince1970: 0))
        loaded.sealIntact = sealIntact
        loaded.sealedApps = sealIntact ? [] : [app]
        return loaded
    }

    /// Sends `event` through a tracked session over `screen`; returns what reached the device, how often the tree was read and the failure.
    private func send(
        _ event: InputEvent, loaded: GuardSources.Loaded, asks: Asks = Asks(approves: true), signedIn: String? = "tester", testDevice: Bool? = nil
    ) async -> (sent: [RecordingInputSession.Call], reads: Int, dispatched: DispatchState, failure: CLIError?) {
        let backend = FakeDeviceBackend(trees: [Self.screen])
        let tracker = DispatchTracker()
        let environment = AppGuard.Environment(confirm: { try asks.ask($0) }, signedIn: { _, _ in signedIn }, isTestDevice: { _ in testDevice })
        var failure: CLIError?
        await GuardSources.$source.withValue({ loaded }) {
            await AppGuard.$environment.withValue(environment) {
                await DispatchTracker.$current.withValue(tracker) {
                    await DeviceActivityLedger.$current.withValue(DeviceActivityLedger()) {
                        do {
                            try await backend.performTracked(event, on: Self.device)
                        } catch {
                            failure = error as? CLIError ?? CLIError(errorDescription: "\(error)")
                        }
                    }
                }
            }
        }
        return (backend.session.calls, backend.treeReads, tracker.state, failure)
    }

    @Test("with no rules anywhere, input is sent without one more read of the screen")
    func noRulesCostsNothing() async {
        let result = await send(.tapAt(x: 100, y: 620), loaded: GuardSources.Loaded())
        #expect(result.sent == [.perform(.tapAt(x: 100, y: 620))])
        #expect(result.reads == 0)
        #expect(result.failure == nil)
    }

    @Test("a tree the command read a moment ago is used again, so a guarded tap reads the screen once")
    func reusesAFreshTree() async throws {
        let backend = FakeDeviceBackend(trees: [Self.screen])
        let loaded = Self.rules()
        try await GuardSources.$source.withValue({ loaded }) {
            try await DeviceActivityLedger.$current.withValue(DeviceActivityLedger()) {
                try await DispatchTracker.$current.withValue(DispatchTracker()) {
                    _ = try await backend.accessibilityTree(for: Self.device)
                    try await backend.performTracked(.tapAt(x: 100, y: 320), on: Self.device)
                    #expect(backend.treeReads == 1)
                    // After an input the screen may have changed, so the next check reads again.
                    try await backend.performTracked(.tapAt(x: 100, y: 320), on: Self.device)
                    #expect(backend.treeReads == 2)
                }
            }
        }
    }

    @Test("a coordinate tap on a never control sends nothing and says whose tap it is")
    func neverIsRefused() async {
        let result = await send(.tapAt(x: 100, y: 720), loaded: Self.rules())
        #expect(result.sent.isEmpty)
        #expect(result.dispatched == .no)
        #expect(result.failure?.reason == .guardedControl)
        #expect(result.failure?.userFacingDescription.contains("\"Password\"") == true)
        #expect(result.failure?.userFacingDescription.contains("Offsider sent nothing") == true)
    }

    @Test("a tap beside the guarded controls goes through, and so does a hardware button")
    func freeInputPasses() async {
        #expect(await send(.tapAt(x: 100, y: 320), loaded: Self.rules()).sent == [.perform(.tapAt(x: 100, y: 320))])
        let button = await send(.shortButtonPress(.home), loaded: Self.rules())
        #expect(button.sent == [.perform(.shortButtonPress(.home))])
        #expect(button.reads == 0)
    }

    @Test("an ask control waits for the person, naming the control, the rule and the login")
    func askIsApproved() async {
        let asks = Asks(approves: true)
        let result = await send(.tapAt(x: 100, y: 620), loaded: Self.rules(), asks: asks)
        #expect(result.sent == [.perform(.tapAt(x: 100, y: 620))])
        #expect(result.failure == nil)
        #expect(asks.reasons.count == 1)
        #expect(asks.reasons.first?.contains("Buy now") == true)
        #expect(asks.reasons.first?.contains("Place an order") == true)
        #expect(asks.reasons.first?.contains("tester") == true)
    }

    @Test("an ask nobody approves sends nothing and hands the agent the words to pass on")
    func askIsDeclined() async {
        let result = await send(.tapAt(x: 100, y: 620), loaded: Self.rules(), asks: Asks(approves: false))
        #expect(result.sent.isEmpty)
        #expect(result.dispatched == .no)
        #expect(result.failure?.reason == .personRequired)
        #expect(result.failure?.ask?.hasPrefix("Can you ") == true)
    }

    @Test("an ask is never offered for an account Offsider did not sign in, a login the rules leave out, or a personal phone")
    func askNeedsATestAccountOnATestDevice() async {
        for (signedIn, askUsers, testDevice) in [(nil, nil, nil), ("owner", ["tester"], nil), ("tester", nil, false)] as [(String?, [String]?, Bool?)] {
            let asks = Asks(approves: true)
            let result = await send(.tapAt(x: 100, y: 620), loaded: Self.rules(askUsers: askUsers), asks: asks, signedIn: signedIn, testDevice: testDevice)
            #expect(result.sent.isEmpty)
            #expect(asks.reasons.isEmpty)
            #expect(result.failure?.reason == .guardedControl)
            #expect(result.failure?.ask?.contains(PersonAsk.devicePlaceholder) == true)
        }
        let allowed = await send(.tapAt(x: 100, y: 620), loaded: Self.rules(askUsers: ["tester"]), testDevice: true)
        #expect(allowed.sent.count == 1)
    }

    @Test("a drag from a guarded control, and Return while one is on screen, are caught too")
    func otherInputs() async {
        let drag = await send(.swipe(100, yStart: 720, xEnd: 300, yEnd: 720, delta: 10, duration: 0.3), loaded: Self.rules())
        #expect(drag.failure?.reason == .guardedControl)
        let key = await send(.shortKeyPress(40), loaded: Self.rules())
        #expect(key.sent.isEmpty)
        #expect(key.failure?.reason == .guardedControl)
        let letter = await send(.shortKeyPress(4), loaded: Self.rules())
        #expect(letter.sent.count == 1)
    }

    @Test("a guarded app sharing the screen with another is still judged, and an app that is not on screen is left alone")
    func everyAppOnScreenIsJudged() {
        func node(_ package: String, _ id: String, y: Double) -> UINode {
            UINode(role: .button, id: id, label: id, frame: FakeUI.frame(20, y, 200, 44), native: .android(AndroidNativeAttributes(package: package)))
        }
        let split = UITree(platform: .android, device: "emulator-5554", roots: [node("com.example.other", "other", y: 100), node(Self.app, "order-confirm", y: 600)])
        #expect(AppGuard.appsOnScreen(split) == ["com.example.other", Self.app])
        #expect(AppGuard.appsOnScreen(Self.screen) == nil)
    }

    @Test("a label the mask file hides stays hidden in the guard's refusal")
    func refusalMasksLabels() async throws {
        let masks = OutputMasks { try! TreeValueMask(plan: MaskPlan(ids: [], labels: [], labelsContaining: ["password"], texts: [], emails: false)) }
        let result = await OutputMasks.$current.withValue(masks) { await send(.tapAt(x: 100, y: 720), loaded: Self.rules()) }
        #expect(result.failure?.reason == .guardedControl)
        #expect(result.failure?.userFacingDescription.contains("Change password") == false)
        #expect(result.failure?.userFacingDescription.contains("password") == true)
    }

    @Test("every input path that skips the tracked session checks the guard itself")
    func sessionlessPathsAreGuarded() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Offsider")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var unguarded: [String] = []
        for file in files where !file.path.contains("/Platform/") && !file.path.contains("/Resources/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".sendDetachedTouch(") || text.contains(".setRangeValue("), !text.contains("AppGuard.check(") { unguarded.append(file.lastPathComponent) }
        }
        #expect(unguarded.isEmpty, "\(unguarded) send input outside TrackedInputSession without AppGuard.check")
    }

    @Test("approvals changed outside Offsider stop input to their app until a person approves again")
    func changedSealStopsInput() async {
        let result = await send(.tapAt(x: 100, y: 320), loaded: Self.rules(sealIntact: false))
        #expect(result.sent.isEmpty)
        #expect(result.failure?.reason == .guardedControl)
        #expect(result.failure?.hint == "offsider guard approve --app \(Self.app)")
    }

    @Test("a guard file that cannot be read stops input, naming the file")
    func brokenFileStopsInput() async {
        var loaded = GuardSources.Loaded()
        loaded.problem = "/repo/offsider.guard.json: unknown key allow; use apps, ask, never or askUsers."
        let result = await send(.tapAt(x: 100, y: 320), loaded: loaded)
        #expect(result.sent.isEmpty)
        #expect(result.failure?.reason == .usage)
        #expect(result.failure?.userFacingDescription.contains("/repo/offsider.guard.json") == true)
    }
}

@Suite("Guard rules on disk")
struct GuardSourcesTests {
    private struct FakeSeal: GuardSealing {
        var record: GuardSealRecord?
        func stored() throws -> GuardSealRecord? { record }
        func store(_ record: GuardSealRecord) throws {}
    }

    private static func repository(_ text: String?) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-guard-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("app/src"), withIntermediateDirectories: true)
        if let text { try Data(text.utf8).write(to: folder.appendingPathComponent(GuardConfig.fileName)) }
        return folder.path
    }

    @Test("the file is found from a folder inside the repository")
    func findsFileFromSubfolder() throws {
        let root = try Self.repository(GuardConfigTests.example)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let loaded = GuardSources.load(from: root + "/app/src", store: nil, seal: FakeSeal())
        #expect(loaded.file?.path == root + "/" + GuardConfig.fileName)
        #expect(loaded.problem == nil)
        #expect(loaded.set(for: "com.mpalmes.offsider.playground").state == .unapproved)
        #expect(loaded.set(for: "com.example.other").state == .missing)
    }

    @Test("no file and no approvals is empty, and a broken file is a problem, never silence")
    func emptyAndBroken() throws {
        let bare = try Self.repository(nil)
        defer { try? FileManager.default.removeItem(atPath: bare) }
        #expect(GuardSources.load(from: bare, store: nil, seal: FakeSeal()).isEmpty)
        let broken = try Self.repository(#"{"apps": ["com.example.app"], "allow": []}"#)
        defer { try? FileManager.default.removeItem(atPath: broken) }
        let loaded = GuardSources.load(from: broken, store: nil, seal: FakeSeal())
        #expect(!loaded.isEmpty)
        #expect(loaded.problem?.contains("unknown key allow") == true)
    }

    @Test("a seal that no longer matches the approvals names every app it covered")
    func brokenSeal() {
        let approvals = GuardApprovals().approving(GuardConfig(apps: ["com.example.app"], rules: [AppGuardTests.order]), source: nil, now: Date(timeIntervalSince1970: 0))
        let snapshot = GuardApprovalsSnapshot(approvals: approvals, data: approvals.encoded())
        #expect(FakeSeal(record: GuardSealRecord(data: snapshot.data, apps: approvals.apps)).check(snapshot).intact)
        let stale = FakeSeal(record: GuardSealRecord(data: Data("older".utf8), apps: ["com.example.removed"])).check(snapshot)
        #expect(!stale.intact)
        #expect(stale.apps == ["com.example.app", "com.example.removed"])
        #expect(!FakeSeal(record: nil).check(snapshot).intact)
        #expect(FakeSeal(record: nil).check(.missing).intact)
    }
}
