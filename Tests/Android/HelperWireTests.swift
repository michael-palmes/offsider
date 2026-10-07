import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android helper wire")
struct HelperWireTests {
    @Test("a frame is a big-endian length, then the payload")
    func framing() throws {
        let frame = try HelperWire.frame(Data("{\"id\":1}".utf8))
        #expect([UInt8](frame.prefix(4)) == [0, 0, 0, 8])
        #expect(frame.dropFirst(4) == Data("{\"id\":1}".utf8))
        #expect([UInt8](try HelperWire.frame(Data(count: 0x0102)).prefix(4)) == [0, 0, 1, 2])
    }

    @Test("frames split at every byte boundary decode to the same payloads")
    func splitAnywhere() throws {
        let payloads = [Data("{\"id\":1,\"ok\":true}".utf8), Data(), Data("{\"event\":\"bye\"}".utf8)]
        let stream = try payloads.reduce(Data()) { $0 + (try HelperWire.frame($1)) }
        for cut in 0...stream.count {
            var decoder = HelperWire.FrameDecoder()
            let first = try decoder.feed(Data(stream.prefix(cut)))
            let rest = try decoder.feed(Data(stream.dropFirst(cut)))
            #expect(first + rest == payloads, "cut at \(cut)")
        }
        var bytewise = HelperWire.FrameDecoder()
        let decoded = try stream.flatMap { try bytewise.feed(Data([$0])) }
        #expect(decoded == payloads)
    }

    @Test("a length over 32 MiB throws as soon as the header arrives")
    func oversized() {
        var decoder = HelperWire.FrameDecoder()
        #expect(throws: HelperProtocolError.self) { try decoder.feed(Data([0x02, 0x00, 0x00, 0x01])) }
        #expect(throws: HelperProtocolError.self) { try HelperWire.frame(Data(count: (32 << 20) + 1)) }
    }

    @Test("the ready line decodes")
    func readyLine() throws {
        let line = #"{"event":"ready","protocol":2,"helper":"1.0.0","pid":25243,"socket":"offsider-4b32b82caf9422438133ded51c063ca6","token":"aa","sdkInt":36}"#
        let ready = try HelperWire.ready(fromLine: line)
        #expect(ready.pid == 25243)
        #expect(ready.socket == "offsider-4b32b82caf9422438133ded51c063ca6")
        #expect(ready.token == "aa")
        #expect(ready.protocol == 2)
    }

    @Test("a ready line without a token, or another event, is refused")
    func badReadyLine() {
        #expect(throws: HelperProtocolError.self) {
            try HelperWire.ready(fromLine: #"{"event":"ready","protocol":2,"helper":"1.0.0","pid":1,"socket":"offsider-1","sdkInt":36}"#)
        }
        #expect(throws: HelperProtocolError.self) {
            try HelperWire.ready(fromLine: #"{"event":"bye","protocol":2,"helper":"1.0.0","pid":1,"socket":"s","token":"t","sdkInt":36}"#)
        }
    }

    @Test("requests carry id and op beside their own fields, with sorted keys")
    func requests() throws {
        #expect(String(decoding: try HelperRequest.hello(token: "t").payload(id: 1), as: UTF8.self) == #"{"id":1,"op":"hello","protocol":2,"token":"t"}"#)
        #expect(String(decoding: try HelperRequest.quit.payload(id: 9), as: UTF8.self) == #"{"id":9,"op":"quit"}"#)
        #expect(String(decoding: try HelperRequest.dump(HelperDumpOptions()).payload(id: 2), as: UTF8.self)
            == #"{"id":2,"idleQuietMs":100,"idleTimeoutMs":500,"notImportant":false,"op":"dump","testTags":true,"visibleOnly":true,"windows":"app"}"#)
    }

    @Test("replies decode leniently: unknown fields are ignored and absent booleans take the helper's defaults")
    func lenientNode() throws {
        let node = try JSONDecoder().decode(HelperNode.self, from: Data(#"{"i":4,"class":"android.widget.Button","bounds":[1,2,3,4],"clickable":true,"enabled":false,"childCount":3,"futureField":{"x":1}}"#.utf8))
        #expect(node.clickable)
        #expect(!node.enabled)
        #expect(node.visibleToUser)
        #expect(!node.checkable)
        #expect(node.children.isEmpty)
        #expect(node.bounds == [1, 2, 3, 4])
    }

    @Test("a window's root is absent when the dump did not walk it, and null when it found none")
    func windowRoots() throws {
        let absent = try JSONDecoder().decode(HelperWindow.self, from: Data(#"{"id":1,"type":"system","layer":1,"bounds":[0,0,1080,142],"active":false,"focused":false}"#.utf8))
        let missing = try JSONDecoder().decode(HelperWindow.self, from: Data(#"{"id":2,"type":"application","layer":0,"bounds":[0,0,1,1],"active":true,"focused":true,"root":null}"#.utf8))
        #expect(!absent.rootRequested && absent.root == nil)
        #expect(missing.rootRequested && missing.root == nil)
    }

    @Test("a range sent as null decodes as not a number instead of failing the dump")
    func nullRange() throws {
        let range = try JSONDecoder().decode(HelperRange.self, from: Data(#"{"type":"float","min":0,"max":1,"current":null}"#.utf8))
        #expect(range.current.isNaN)
        #expect(range.max == 1)
    }

    @Test("a paste reply and a refusal carry the field's inputType; an older reply without it still decodes")
    func pasteReplyDecodes() throws {
        let reply = try JSONDecoder().decode(HelperTextResult.self, from: Data(#"{"id":4,"ok":true,"className":"android.widget.EditText","resourceId":"amount","inputType":8194,"length":3,"eventSeq":9}"#.utf8))
        #expect(reply == HelperTextResult(className: "android.widget.EditText", resourceId: "amount", inputType: 8194, length: 3))
        let older = try JSONDecoder().decode(HelperTextResult.self, from: Data(#"{"className":"android.widget.EditText","resourceId":null,"length":0}"#.utf8))
        #expect(older.inputType == nil)
        let refusal = try JSONDecoder().decode(HelperErrorBody.self, from: Data(#"{"code":"secure-refused","message":"m","detail":null,"className":"android.widget.EditText","resourceId":"pin","inputType":18}"#.utf8))
        #expect(refusal.inputType == 18)
        #expect(AndroidFieldInfo.describe(0x2002) == "number|decimal")
        #expect(AndroidFieldInfo.describe(0x21) == "text|email")
        #expect(AndroidFieldInfo.describe(3) == "phone")
    }

    @Test("paste names the field it may go into, an id the field lacks left out, and nothing when no field is known")
    func pasteRequestNamesField() throws {
        let amount = AndroidFieldInfo(className: "android.widget.EditText", resourceId: "amount", inputType: 2)
        #expect(String(decoding: try HelperRequest.paste(expecting: amount).payload(id: 4), as: UTF8.self)
            == #"{"expectClass":"android.widget.EditText","expectResourceId":"amount","id":4,"op":"paste"}"#)
        let unnamed = AndroidFieldInfo(className: "android.widget.EditText", resourceId: nil)
        #expect(String(decoding: try HelperRequest.paste(expecting: unnamed).payload(id: 5), as: UTF8.self)
            == #"{"expectClass":"android.widget.EditText","id":5,"op":"paste"}"#)
        #expect(String(decoding: try HelperRequest.paste(expecting: nil).payload(id: 6), as: UTF8.self) == #"{"id":6,"op":"paste"}"#)
    }

    @Test("a node showing its hint decodes as such; older dumps without the flag read as not showing it")
    func showingHintDecodes() throws {
        let hinted = try JSONDecoder().decode(HelperNode.self, from: Data(#"{"i":1,"class":"android.widget.EditText","text":"Amount","hint":"Amount","bounds":[0,0,1,1],"editable":true,"showingHint":true}"#.utf8))
        #expect(hinted.showingHint)
        let older = try JSONDecoder().decode(HelperNode.self, from: Data(#"{"i":1,"class":"android.widget.EditText","text":"Amount","bounds":[0,0,1,1]}"#.utf8))
        #expect(!older.showingHint)
    }
}
