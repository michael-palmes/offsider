import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android toasts")
@MainActor
struct AndroidToastTests {
    static let toasts = #""toastPackage":"com.mpalmes.offsider.playground.rn","toasts":[{"seq":4,"text":"Draft saved","package":"com.mpalmes.offsider.playground.rn","ageMs":2400},{"seq":5,"text":"Sent","package":"com.mpalmes.offsider.playground.rn","ageMs":120}],"#
    static let dumpWithToasts = FakeHelperDevice.tapTestDump.replacingOccurrences(of: #""truncated":false"#, with: toasts + #""truncated":false"#)

    static func dumpRequests(_ device: FakeHelperDevice) -> [String] {
        device.frames.filter { $0.op == "dump" }.map(\.json)
    }

    @Test("an emulator's read asks for the app in front's toasts in the same dump, and lists them oldest first")
    func emulatorReadListsToasts() async throws {
        let rig = try HelperRig()
        rig.device.answer = { _, op, _ in op == "dump" ? .ok(Self.dumpWithToasts) : nil }
        let tree = try await rig.read()

        #expect(rig.device.ops == ["hello", "dump"])
        #expect(Self.dumpRequests(rig.device).allSatisfy { $0.contains(#""toasts":"front""#) })
        #expect(tree.toasts?.map(\.text) == ["Draft saved", "Sent"])
        #expect(tree.toasts?.map(\.ageMs) == [2400, 120])
        #expect(tree.toasts?.allSatisfy { $0.package == "com.mpalmes.offsider.playground.rn" } == true)
        await rig.backend.close()
    }

    @Test("toasts from a restarted helper never share a key with the ones before it")
    func keysCarryTheHelper() throws {
        let dump = try JSONDecoder().decode(HelperDump.self, from: Data(Self.dumpWithToasts.utf8))
        let first = HelperTreeMapping.toasts(from: dump, pid: 100)?.map(\.key) ?? []
        let second = HelperTreeMapping.toasts(from: dump, pid: 200)?.map(\.key) ?? []
        #expect(first.count == 2)
        #expect(Set(first).isDisjoint(with: second))
    }

    @Test("a reply with no toasts field means the source cannot see them, not that there are none")
    func noFieldIsUnknown() throws {
        let plain = try JSONDecoder().decode(HelperDump.self, from: Data(FakeHelperDevice.tapTestDump.utf8))
        let empty = try JSONDecoder().decode(HelperDump.self, from: Data(FakeHelperDevice.tapTestDump.replacingOccurrences(of: #""truncated":false"#, with: #""toasts":[],"truncated":false"#).utf8))
        #expect(HelperTreeMapping.toasts(from: plain, pid: 1) == nil)
        #expect(HelperTreeMapping.toasts(from: empty, pid: 1) == [])
    }

    @Test("the read for masks, which keeps every view, asks for no toasts")
    func maskReadAsksForNone() async throws {
        let rig = try HelperRig()
        _ = try await rig.backend.maskTree(for: HelperRig.device)
        let requests = Self.dumpRequests(rig.device)
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { !$0.contains(#""toasts""#) })
        await rig.backend.close()
    }

    static let phone = "R58M123ABC"

    @Test("on a phone only the command's app, the checked pinned app or the only pinned one is asked for; a test device asks for the app in front", arguments: [
        (AndroidAppScope(permitted: [], managedCeiling: nil, needsTarget: true, target: "com.example.named"), nil, "com.example.named"),
        (AndroidAppScope(permitted: ["com.example.pinned"], managedCeiling: nil), nil, "com.example.pinned"),
        (AndroidAppScope(permitted: ["com.example.one", "com.example.two"], managedCeiling: nil), "com.example.two", "com.example.two"),
        (AndroidAppScope(permitted: ["com.example.one", "com.example.two"], managedCeiling: nil), "com.example.other", nil),
        (AndroidAppScope(permitted: ["com.example.one", "com.example.two"], managedCeiling: nil), nil, nil),
        (AndroidAppScope(permitted: [], managedCeiling: nil, wholeDevice: true), nil, "front"),
    ] as [(AndroidAppScope, String?, String?)])
    func phoneScope(scope: AndroidAppScope, checked: String?, expected: String?) throws {
        let (backend, _) = try AndroidBackendHelperTests.phoneBackend(top: nil)
        backend.appScopes[Self.phone] = scope
        if let checked { backend.foregroundChecks[Self.phone] = (ContinuousClock.now, checked) }
        #expect(backend.toastScope(Self.phone) == expected)
        #expect(backend.toastScope("emulator-5556") == "front")
    }
}

extension AndroidToastTests {
    @Test("a phone's helper starts holding only its allowed apps' toasts, none with no app named; an emulator's and a test device's hold every package's", arguments: [
        (AndroidAppScope(permitted: [], managedCeiling: nil, needsTarget: true, target: "com.example.named"), ["com.example.named"]),
        (AndroidAppScope(permitted: [], managedCeiling: nil, needsTarget: true), []),
        (AndroidAppScope(permitted: ["com.example.two", "com.example.one"], managedCeiling: nil), ["com.example.one", "com.example.two"]),
        (AndroidAppScope(permitted: [], managedCeiling: nil, wholeDevice: true), nil),
    ] as [(AndroidAppScope, [String]?)])
    func heldPackages(scope: AndroidAppScope, expected: [String]?) throws {
        let (backend, _) = try AndroidBackendHelperTests.phoneBackend(top: nil)
        backend.appScopes[Self.phone] = scope
        #expect(backend.heldToastPackages(Self.phone) == expected)
        #expect(backend.heldToastPackages("emulator-5556") == nil)
    }

    @Test("the start script passes the held packages to the helper, sorted and quoted, and nothing when every package is held")
    func startScriptCarriesPackages() {
        let held = HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: nil, toastPackages: ["com.example.two", "com.example.one"])
        #expect(held.hasSuffix(" --toast-packages 'com.example.one,com.example.two'"))
        #expect(!HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: nil).contains("--toast-packages"))
        #expect(HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: nil, toastPackages: []).hasSuffix(" --toast-packages ''"))
    }

    @Test("a toast entry that does not decode is dropped and the tree still reads")
    func badToastEntryIsDropped() throws {
        let reply = FakeHelperDevice.tapTestDump.replacingOccurrences(
            of: #""truncated":false"#, with: #""toasts":[{"seq":1,"text":"Draft saved"},{"seq":2,"text":"Sent","package":"com.mpalmes.offsider.playground.rn","ageMs":10}],"truncated":false"#
        )
        let dump = try JSONDecoder().decode(HelperDump.self, from: Data(reply.utf8))
        #expect(dump.toasts?.map(\.text) == ["Sent"])
        #expect(!dump.windows.isEmpty)
    }
}
