import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android slider action")
@MainActor
struct AndroidSliderActionTests {
    static let device = HelperRig.device

    /// slider-value-test as the helper reported it, trimmed to the back button and the React Native SeekBar at 25 %.
    nonisolated static func sliderDump(generation: Int = 1, current: Int = 2500) -> String {
        """
        {"generation":\(generation),"idle":true,\(FakeHelperDevice.display),"windows":[\(FakeHelperDevice.statusBar),{"id":2292,"type":"application","layer":0,"title":"OffsiderPlaygroundRN","bounds":[0,0,1080,2424],"active":true,"focused":true,"root":{"i":0,"class":"android.widget.FrameLayout","package":"com.mpalmes.offsider.playground.rn","bounds":[0,0,1080,2424],"children":[{"i":1,"class":"android.widget.Button","package":"com.mpalmes.offsider.playground.rn","resourceId":"BackButton","contentDescription":"Offsider Playground","bounds":[21,142,137,258],"clickable":true,"focusable":true},{"i":2,"class":"android.widget.SeekBar","package":"com.mpalmes.offsider.playground.rn","resourceId":"slider-value-slider","contentDescription":"Slider Value Slider","stateDescription":"25%","bounds":[42,1010,1038,1057],"focusable":true,"rangeInfo":{"type":"int","min":0,"max":10000,"current":\(current)}}]}}],"truncated":false,"eventSeq":3}
        """
    }

    nonisolated static let progressReply = #"{"range":{"type":"int","min":0,"max":10000,"current":4000}}"#

    static func rig(answer: @escaping @Sendable (_ process: Int, _ op: String, _ json: String) -> FakeHelperDevice.Answer? = { _, op, _ in
        op == "setProgress" ? .ok(progressReply) : nil
    }) throws -> HelperRig {
        let device = FakeHelperDevice()
        device.dump = sliderDump()
        device.answer = answer
        return try HelperRig(device)
    }

    static func slider(in tree: UITree) throws -> UINode {
        try #require(tree.roots.flatMap { $0.flattened() }.first { $0.id == "slider-value-slider" })
    }

    static func object(_ json: String) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    @Test("the matched slider is named by its dump generation, index, class and id, with the value in its own units")
    func sendsReferenceAndValue() async throws {
        let rig = try Self.rig()
        let slider = try Self.slider(in: try await rig.read())

        let outcome = try await rig.backend.setRangeValue(0.4, of: slider, on: Self.device)

        #expect(outcome == .performed(reachable: 0.4))
        let request = try #require(rig.device.frames.first { $0.op == "setProgress" })
        let sent = try Self.object(request.json)
        #expect(sent["node"] as? NSDictionary == [
            "generation": 1, "index": 2, "className": "android.widget.SeekBar", "resourceId": "slider-value-slider",
        ] as NSDictionary)
        #expect(sent["value"] as? Int == 4000)
        #expect(sent["expect"] as? NSDictionary == ["min": 0, "max": 10000] as NSDictionary)
        await rig.backend.close()
    }

    @Test("a slider that changed in a later dump is stale without a request")
    func laterGenerationIsStale() async throws {
        let rig = try Self.rig { _, op, json in
            if op == "dump", !json.contains(#""id":2,"#) { return .ok(Self.sliderDump(generation: 2, current: 3000)) }
            return op == "setProgress" ? .ok(Self.progressReply) : nil
        }
        let slider = try Self.slider(in: try await rig.read())
        _ = try await rig.read()

        #expect(try await rig.backend.setRangeValue(0.4, of: slider, on: Self.device) == .stale)
        #expect(!rig.device.ops.contains("setProgress"))
        await rig.backend.close()
    }

    @Test("a slider read by a helper that has since restarted is stale without a request")
    func restartedHelperIsStale() async throws {
        let rig = try Self.rig { process, op, _ in
            if process == 1, op == "display" { return .bye("idle") }
            return op == "setProgress" ? .ok(Self.progressReply) : nil
        }
        let slider = try Self.slider(in: try await rig.read())
        let session = try #require(rig.backend.runningHelper(for: Self.device.rawValue))
        _ = try await session.refreshDisplay()

        #expect(try await rig.backend.setRangeValue(0.4, of: slider, on: Self.device) == .stale)
        #expect(!rig.device.ops.contains("setProgress"))
        await rig.backend.close()
    }

    static let refusals: [(code: String, outcome: RangeActionOutcome)] = [
        ("stale-node", .stale),
        ("action-unsupported", .unsupported(reason: "android.widget.SeekBar does not offer ACTION_SET_PROGRESS")),
        ("action-failed", .unsupported(reason: "android.widget.SeekBar does not offer ACTION_SET_PROGRESS")),
    ]

    @Test("the helper's refusals become stale or unsupported, so the command finds the slider again or drags it", arguments: refusals.indices)
    func refusals(row: Int) async throws {
        let (code, expected) = Self.refusals[row]
        let rig = try Self.rig { _, op, _ in
            op == "setProgress" ? .error(code: code, message: "android.widget.SeekBar does not offer ACTION_SET_PROGRESS") : nil
        }
        let slider = try Self.slider(in: try await rig.read())

        #expect(try await rig.backend.setRangeValue(0.4, of: slider, on: Self.device) == expected)
        await rig.backend.close()
    }

    @Test("without the helper, the error says slider needs it and why it is unavailable")
    func fallbackRefuses() async throws {
        let device = FakeHelperDevice(starts: [.exit(status: 6, stderr: "java.lang.VerifyError: bad dex\n")])
        let rig = try HelperRig(device)
        let tree = try await rig.read()
        let node = try #require(tree.roots.first)

        let error = await #expect(throws: AndroidError.self) { try await rig.backend.setRangeValue(0.4, of: node, on: Self.device) }
        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message == "slider on Android reads slider values through the UiAutomation helper, which is unavailable on emulator-5556 (it exited with status 6 before it was ready: java.lang.VerifyError: bad dex).")
    }

    @Test("with OFFSIDER_ANDROID_TREE=uiautomator, the error says to unset it")
    func forcedUIAutomatorRefuses() async throws {
        let rig = try HelperRig(environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        let node = try #require(try await rig.read().roots.first)

        let error = await #expect(throws: AndroidError.self) { try await rig.backend.setRangeValue(0.4, of: node, on: Self.device) }
        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message == "slider on Android reads slider values through the UiAutomation helper, and OFFSIDER_ANDROID_TREE is uiautomator. Unset it, then retry.")
        #expect(rig.startShells == 0)
    }
}
