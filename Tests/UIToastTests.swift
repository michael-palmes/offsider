import Foundation
import OffsiderCore
import Testing

@Suite("Android toasts in the tree")
struct UIToastTests {
    static let package = "com.mpalmes.offsider.playground.rn"

    static func tree(_ toasts: [UIToast]?, platform: DevicePlatform = .android) -> UITree {
        var tree = UITree(platform: platform, device: "emulator-5554", roots: [UINode(role: .application, label: "OffsiderPlaygroundRN", frame: UIFrame(x: 0, y: 0, width: 411, height: 923), native: .android(AndroidNativeAttributes(package: package)))])
        tree.toasts = toasts
        return tree
    }

    static func toast(_ text: String, ageMs: Int = 1500, key: String = "1-1") -> UIToast {
        UIToast(key: key, text: text, package: package, ageMs: ageMs)
    }

    static func context(_ tree: UITree) throws -> [String: Any] {
        let object = try #require(try JSONSerialization.jsonObject(with: tree.jsonData()) as? [String: Any])
        return try #require(object["context"] as? [String: Any])
    }

    @Test("describe-ui JSON lists each toast's text, package and age under context, and an Android read with none says so")
    func jsonListsToasts() throws {
        let listed = try #require(try Self.context(Self.tree([Self.toast("Draft saved")]))["toasts"] as? [[String: Any]])
        #expect(listed.count == 1)
        #expect(listed.first?["text"] as? String == "Draft saved")
        #expect(listed.first?["package"] as? String == Self.package)
        #expect((listed.first?["ageMs"] as? NSNumber)?.intValue == 1500)
        #expect(listed.first?["key"] == nil)
        #expect((try Self.context(Self.tree([]))["toasts"] as? [Any])?.isEmpty == true)
    }

    @Test("a source that cannot see toasts adds no toasts key, so iOS output is unchanged")
    func noKeyWithoutSource() throws {
        #expect(try Self.context(Self.tree(nil, platform: .ios))["toasts"] == nil)
    }

    @Test("the text form adds one line per toast, with its age")
    func textLines() {
        let tree = Self.tree([Self.toast("Draft saved", ageMs: 2400, key: "1-1"), Self.toast("Sent", ageMs: 300, key: "1-2")])
        let text = String(decoding: UITreeRenderer.render(tree, .summary), as: UTF8.self)
        #expect(text.contains("# toast: \"Draft saved\" from \(Self.package), 2 s ago\n"))
        #expect(text.contains("# toast: \"Sent\" from \(Self.package), just now\n"))
        let old = String(decoding: UITreeRenderer.render(Self.tree([Self.toast("Draft saved", ageMs: 12_400)]), .summary), as: UTF8.self)
        #expect(old.contains("# toast: \"Draft saved\" from \(Self.package), 12 s ago, off screen by now\n"))
    }

    @Test("a decoded describe-ui JSON keeps its toasts")
    func roundTrip() throws {
        let decoded = try UITree(jsonData: Self.tree([Self.toast("Draft saved")]).jsonData())
        #expect(decoded.context.toasts?.map(\.text) == ["Draft saved"])
        #expect(decoded.context.toasts?.first?.ageMs == 1500)
    }

    @Test("toast text is masked as element text is: a label part, a value pattern, a one-time code, and in the cache too", arguments: [
        (TreeValueMask(labelContains: ["code"]), "Your login code 4821 is ready", "[redacted] code [redacted]"),
        (TreeValueMask(patterns: [try! NSRegularExpression(pattern: "acct-[0-9]+")]), "Moved to acct-99812", "Moved to [redacted]"),
        (TreeValueMask.none, "Your code is 482913", "Your code is [redacted]"),
    ])
    func masked(mask: TreeValueMask, text: String, shown: String) {
        let output = Self.tree([Self.toast(text)]).redacted(mask)
        #expect(output.toasts?.first?.text == shown)
        #expect(output.redaction?.redacted == 1)
        #expect(output.context.headerLines.contains { $0.contains(shown) })
        #expect(!String(decoding: output.jsonData(), as: UTF8.self).contains(text))
    }

    @Test("a mask on a toast's exact text, like one on a label, leaves it shown and counts nothing")
    func exactLabelShows() {
        let output = Self.tree([Self.toast("Draft saved")]).redacted(TreeValueMask(labels: ["Draft saved"]))
        #expect(output.toasts?.first?.text == "Draft saved")
        #expect(output.redaction?.isEmpty == true)
    }

    @Test("describe-ui --diff prints every toast the read lists, since no cached tree holds one")
    func diffHeader() {
        let text = TreeDiffRenderer.render(Self.tree([Self.toast("Draft saved")]), base: nil, options: UITreeRenderOptions(format: .text), now: Date())
        #expect(text.contains("# toast: \"Draft saved\" from \(Self.package), 1 s ago\n"))
    }

    @Test("--toast matches the whole text as --label matches a label: spacing and curly quotes aside, never a part of it", arguments: [
        ("Draft  saved", true), ("  Draft saved ", true), ("Draft saved", true), ("draft saved", false), ("Draft", false), ("Draft saved!", false),
    ])
    func matching(wanted: String, matches: Bool) {
        #expect(Self.toast("Draft saved").matches(wanted) == matches)
    }

    @Test("the tree cache never holds a toast: a record written from a read that listed one has no trace of its text")
    func neverCached() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let activity = DeviceActivityLedger.Activity(
            device: DeviceID(rawValue: "emulator-5554", platform: .android), tree: Self.tree([Self.toast("Draft saved")]), treeReadAt: now
        )
        let record = try #require(TreeCacheRecord.committing(activity, previous: nil, command: "describe-ui", inputAtEnd: false, bootMarker: nil, now: now))
        #expect(!String(decoding: record.encoded(), as: UTF8.self).contains("Draft saved"))
        #expect(record.tree?.toasts == nil)
    }
}
