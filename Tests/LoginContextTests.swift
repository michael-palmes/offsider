import Foundation
import OffsiderCore
import Testing

@Suite("Login context")
struct LoginContextTests {
    private func tag(_ raw: String) throws -> LoginTag { try #require(LoginTag(rawValue: raw)) }

    private func entry(_ key: String, _ tags: [String], isDefault: Bool = false, about: String? = nil) throws -> LoginEntry {
        LoginEntry(key: key, isDefault: isDefault, context: LoginContext(about: about, tags: try tags.map(tag)))
    }

    @Test("a tag is a lowercase word or key=value, and platform takes only ios or android")
    func tagRules() throws {
        #expect(try tag(" Role=Admin ").rawValue == "role=admin")
        #expect(try tag("beta").value == nil)
        #expect(try tag("env=staging").key == "env")
        #expect(try tag("region=ap-southeast-2").value == "ap-southeast-2")
        #expect(try tag("platform=IOS").rawValue == "platform=ios")
        #expect(LoginTag(rawValue: "platform=web") == nil)
        #expect(LoginTag(rawValue: "platform") == nil)
        #expect(LoginTag(rawValue: "-beta") == nil)
        #expect(LoginTag(rawValue: "role=") == nil)
        #expect(LoginTag(rawValue: "role=a=b") == nil)
        #expect(LoginTag(rawValue: "two words") == nil)
        #expect(LoginTag(rawValue: "user=ada@example.com") == nil)
        #expect(LoginTag(rawValue: "café") == nil)
        #expect(LoginTag(rawValue: String(repeating: "k", count: 33)) == nil)
        #expect(LoginTag(rawValue: "k=" + String(repeating: "v", count: 65)) == nil)
        #expect(LoginTag.problem("platform=web")?.contains("ios or android") == true)
        #expect(LoginTag.problem("bad tag")?.contains("1 to 32 characters") == true)
        #expect(LoginTag.problem("beta") == nil)
    }

    @Test("a note is one line of at most 200 characters, with no control, bidi or email-like text")
    func noteRules() throws {
        #expect(try LoginContext.note("  Admin on staging  ", .about) == "Admin on staging")
        #expect(try LoginContext.note("", .state) == "")
        #expect(LoginContext.noteProblem("Admin\non staging") == .control)
        #expect(LoginContext.noteProblem("Admin\ton staging") == .control)
        #expect(LoginContext.noteProblem("Admin\u{2028}on staging") == .control)
        #expect(LoginContext.noteProblem("Admin \u{202E}gnigats") == .bidi)
        #expect(LoginContext.noteProblem("Admin \u{2066}x\u{2069}") == .bidi)
        #expect(LoginContext.noteProblem(String(repeating: "a", count: 200)) == nil)
        #expect(LoginContext.noteProblem(String(repeating: "a", count: 201)) == .tooLong)
        #expect(LoginContext.noteProblem("Signs in as admin@example.com") == .email)
        #expect(LoginContext.noteProblem("Admin on staging, 3 items in the cart") == nil)
        let refused = #expect(throws: LoginContextProblem.self) { try LoginContext.note("qa@example.com", .avoid) }
        #expect(refused?.message.hasPrefix("--avoid looks like it holds an email address.") == true)
        #expect(refused?.message.contains("qa@example.com") == false)
    }

    @Test("storage is version 2 JSON with empty keys and default settings left out, and it round-trips")
    func storageShape() throws {
        let updated = try Date("2026-10-11T09:30:00Z", strategy: .iso8601)
        let context = LoginContext(about: "Admin on staging", state: "3 items in the cart", tags: [try tag("role=admin"), try tag("env=staging"), try tag("role=admin")], updated: updated)
        let json = String(decoding: context.storageData(), as: UTF8.self)
        #expect(json == #"{"v":2,"about":"Admin on staging","state":"3 items in the cart","tags":["env=staging","role=admin"],"updated":"2026-10-11T09:30:00Z"}"#)
        #expect(LoginContext.read(context.storageData()) == .saved(context))
        #expect(String(decoding: LoginContext.empty.storageData(), as: UTF8.self) == #"{"v":2}"#)

        let guarded = LoginContext(tags: [try tag("role=admin")], confirm: true, devices: .any)
        #expect(String(decoding: guarded.storageData(), as: UTF8.self) == #"{"v":2,"tags":["role=admin"],"confirm":true,"devices":"any"}"#)
        #expect(LoginContext.read(guarded.storageData()) == .saved(guarded))
    }

    @Test("the mirror copies confirm and devices from the encrypted data, and a bad mirror is damaged")
    func mirror() throws {
        let credential = try #require(LoginCredential(username: "qa@example.com", password: "pw-1234"))
        let stored = StoredLogin(credential: credential, confirm: true, devices: .any)
        let mirrored = LoginContext(about: "Member").mirroring(stored)
        #expect(mirrored.confirm)
        #expect(mirrored.devices == .any)
        #expect(mirrored.about == "Member")
        #expect(LoginContext.read(Data(#"{"v":2,"devices":"phones"}"#.utf8)) == .damaged)
        #expect(LoginContext.read(Data(#"{"v":2,"confirm":"yes"}"#.utf8)) == .damaged)
        let edited = try LoginContextEdit(about: "Admin").applied(to: mirrored, now: Date(timeIntervalSince1970: 1_791_712_931))
        #expect(edited.confirm && edited.devices == .any)
    }

    @Test("a login saved by 0.9.0 reads as empty, unknown keys are ignored, and a newer version is reported")
    func readingStoredContext() {
        #expect(LoginContext.read(nil) == .saved(.empty))
        #expect(LoginContext.read(Data()) == .saved(.empty))
        #expect(LoginContext.read(Data(#"{"v":1,"about":"Member","colour":"blue"}"#.utf8)) == .saved(LoginContext(about: "Member")))
        #expect(LoginContext.read(Data(#"{"v":2,"about":"Member"}"#.utf8)) == .saved(LoginContext(about: "Member")))
        #expect(LoginContext.read(Data(#"{"v":3,"about":"Member"}"#.utf8)) == .newer(3))
        #expect(LoginContext.read(Data("not json".utf8)) == .damaged)
        #expect(LoginContext.read(Data(#"{"about":"Member"}"#.utf8)) == .damaged)
        #expect(LoginContext.read(Data(#"{"v":1,"tags":["Bad Tag"]}"#.utf8)) == .damaged)
        #expect(LoginContext.read(Data(#"{"v":1,"about":"ada@example.com"}"#.utf8)) == .damaged)
        #expect(LoginEntry(key: "qa", stored: .newer(2)).context == .empty)
    }

    @Test("an edit clears tags, then untags, then tags, and stamps updated only when something changed")
    func editOrder() throws {
        let earlier = try Date("2026-10-01T00:00:00Z", strategy: .iso8601)
        let now = try Date("2026-10-11T09:30:00Z", strategy: .iso8601)
        let start = LoginContext(about: "Admin", tags: [try tag("credit"), try tag("env=staging")], updated: earlier)

        let swapped = try LoginContextEdit(tag: [try tag("credit")], untag: [try tag("credit")], clearTags: true).applied(to: start, now: now)
        #expect(swapped.tags == [try tag("credit")])
        #expect(swapped.updated == now)

        let same = try LoginContextEdit(about: "Admin", tag: [try tag("credit")]).applied(to: start, now: now)
        #expect(same == start)

        let cleared = try LoginContextEdit(about: "", state: "No orders").applied(to: start, now: now.addingTimeInterval(0.7))
        #expect(cleared.about == nil)
        #expect(cleared.state == "No orders")
        #expect(cleared.updated == now)
    }

    @Test("a login holds at most 16 tags")
    func tagCap() throws {
        let sixteen = try (1...16).map { try tag("t\($0)") }
        let full = try LoginContextEdit(tag: sixteen).applied(to: .empty, now: Date())
        #expect(full.tags.count == 16)
        let over = #expect(throws: LoginContextProblem.self) { try LoginContextEdit(tag: [try tag("t17")]).applied(to: full, now: Date()) }
        #expect(over?.message.contains("at most 16 tags") == true)
        #expect(try LoginContextEdit(tag: [try tag("t17")], untag: [try tag("t1")]).applied(to: full, now: Date()).tags.count == 16)
    }

    @Test("parsing flags names the flag and the rule")
    func parsingFlags() {
        let tagProblem = #expect(throws: LoginContextProblem.self) {
            try LoginContextEdit.parse(about: nil, avoid: nil, state: nil, tag: ["Bad Tag"], untag: [], clearTags: false)
        }
        #expect(tagProblem?.message.hasPrefix("--tag ") == true)
        #expect(tagProblem?.message.contains(LoginTag.rule) == true)
        let noteProblem = #expect(throws: LoginContextProblem.self) {
            try LoginContextEdit.parse(about: nil, avoid: nil, state: "one\ntwo", tag: [], untag: [], clearTags: false)
        }
        #expect(noteProblem?.message.hasPrefix("--state ") == true)
        #expect(LoginContextEdit().isEmpty)
        #expect(!LoginContextEdit(clearTags: true).isEmpty)
    }

    @Test("--where matches every tag as a whole, and a bare word never matches a key=value tag")
    func whereMatching() throws {
        let admin = try entry("qa-admin", ["role=admin", "env=staging", "credit"])
        #expect(LoginSelection.matches(admin, where: [try tag("role=admin")]))
        #expect(LoginSelection.matches(admin, where: [try tag("role=admin"), try tag("credit")]))
        #expect(!LoginSelection.matches(admin, where: [try tag("role=admin"), try tag("env=prod")]))
        #expect(!LoginSelection.matches(admin, where: [try tag("role")]))
        #expect(!LoginSelection.matches(try entry("qa", ["role"]), where: [try tag("role=admin")]))
        #expect(!LoginSelection.matches(LoginEntry(key: "qa", stored: .newer(2)), where: [try tag("credit")]))
    }

    @Test("selection picks by name, by tags or by default, and the default never breaks a tie")
    func selectionOutcomes() throws {
        let admin = try entry("qa-admin", ["role=admin", "env=staging"], isDefault: true, about: "Admin on staging")
        let member = try entry("qa-member", ["role=member", "env=staging"])
        let all = [admin, member]
        #expect(LoginSelection.resolve(entries: all, name: "qa-member", where: []) == .chosen(member))
        #expect(LoginSelection.resolve(entries: all, name: "qa-owner", where: []) == .missing("qa-owner"))
        #expect(LoginSelection.resolve(entries: [], name: nil, where: []) == .noneSaved)
        #expect(LoginSelection.resolve(entries: [], name: nil, where: [try tag("credit")]) == .noneSaved)
        #expect(LoginSelection.resolve(entries: all, name: nil, where: []) == .chosen(admin))
        #expect(LoginSelection.resolve(entries: all, name: nil, where: [try tag("role=member")]) == .chosen(member))
        #expect(LoginSelection.resolve(entries: all, name: nil, where: [try tag("env=staging")]) == .ambiguous(all))
        #expect(LoginSelection.resolve(entries: all, name: nil, where: [try tag("env=prod")]) == .noMatch(all))

        let unmarked = [try entry("dev", []), try entry("qa", [])]
        #expect(LoginSelection.resolve(entries: unmarked, name: nil, where: []) == .noDefault(unmarked))
        #expect(LoginSelection.resolve(entries: [unmarked[1]], name: nil, where: []) == .chosen(unmarked[1]))

        #expect(LoginSelection.line(admin) == "qa-admin (env=staging role=admin · Admin on staging)")
        #expect(LoginSelection.line(LoginEntry(key: LoginCredential.defaultAccountKey)) == "default")
    }

    @Test("the platform refinement is offered only when it leaves exactly one match")
    func platformRefinement() throws {
        let iosAdmin = try entry("ios-admin", ["role=admin", "platform=ios"])
        let androidAdmin = try entry("android-admin", ["role=admin", "platform=android"])
        let anyAdmin = try entry("admin", ["role=admin"])
        let filter = [try tag("role=admin")]
        #expect(LoginSelection.platformRefinement([iosAdmin, androidAdmin], where: filter, platform: .ios) == LoginTag(platform: .ios))
        #expect(LoginSelection.platformRefinement([iosAdmin, anyAdmin], where: filter, platform: .android) == nil)
        let twoIOS = try entry("ios-admin-2", ["role=admin", "platform=ios"])
        #expect(LoginSelection.platformRefinement([iosAdmin, twoIOS], where: filter, platform: .ios) == nil)
        #expect(LoginSelection.platformRefinement([iosAdmin, androidAdmin], where: filter + [try tag("platform=ios")], platform: .ios) == nil)
    }
}
