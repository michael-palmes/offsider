import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android raw tree capture")
@MainActor
struct AndroidRawTreeTests {
    @Test("the raw source is the helper's dump reply, which maps to the same tree describe-ui reads")
    func rawSourceMapsLikeDescribeUI() async throws {
        let rig = try HelperRig()
        let raw = try await rig.backend.rawAccessibilitySource(for: HelperRig.device)
        let tree = try await rig.read()
        await rig.backend.close()

        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(object["id"] == nil)
        #expect(object["ok"] == nil)
        #expect(rig.device.ops.filter { $0 == "dump" }.count == 2)

        let dump = try JSONDecoder().decode(HelperDump.self, from: raw)
        let scale = try #require(AndroidDisplayGeometry(display: dump.display)).scale
        #expect(HelperTreeMapping.roots(from: dump, scale: scale, pid: 0).roots == tree.roots)
    }

    @Test("a passed-through reply keeps its booleans, integers, fractions, nulls and nesting")
    func rawJSONKeepsTypes() throws {
        let reply = try JSONDecoder().decode(HelperRawJSON.self, from: Data(#"{"a":true,"b":3,"c":2.5,"d":null,"e":["x",{"f":false}]}"#.utf8))
        let data = try JSONSerialization.data(withJSONObject: reply.value, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":true,"b":3,"c":2.5,"d":null,"e":["x",{"f":false}]}"#)
    }
}
