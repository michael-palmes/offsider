import Foundation
import Testing

/// Saved users with tags and notes, `--where`, and who Offsider last signed in, on the playground's user switch screen.
@Suite("React Native login", .serialized, .enabled(if: RNPlatform.anyEnabled), SavedUsersScope())
struct ReactNativeLoginTests {
    typealias Users = RNLoginUsers

    @Test("status lists each user's tags and notes with no username, and names the username only for one user", arguments: RNPlatform.enabled)
    func listShowsContext(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        let output = try await RNLogin.offsider("credential status --app \(Users.app) --json")
        #expect(output.exitCode == 0, "\(output.stderr)")
        RNLogin.expectNoSecrets(output, "credential status")
        let report = try RNLogin.object(output, "credential status")

        #expect(report["version"] as? Int == 2)
        #expect(report["action"] as? String == "status")
        #expect(report["app"] as? String == Users.app)
        #expect(report["signedInHere"] == nil, "signedInHere needs a device")
        #expect(RNLogin.names(in: report).sorted() == Users.all.map(\.name).sorted())
        for user in Users.all {
            let listed = try #require(RNLogin.user(user.name, in: report))
            #expect(listed["tags"] as? [String] == user.tags, "\(user.name)")
            #expect(listed["about"] as? String == user.about, "\(user.name)")
            #expect(listed["avoid"] as? String == user.avoid, "\(user.name)")
            #expect(listed["state"] as? String == user.state, "\(user.name)")
            #expect(listed["updated"] is String, "\(user.name)")
            #expect(listed["default"] as? Bool == (user.name == Users.admin.name), "\(user.name)")
            #expect(listed["username"] == nil, "\(user.name)")
        }

        let here = try await RNLogin.status(on: app)
        #expect(here["signedInHere"] is NSNull, "with a device, signedInHere is null while nobody is signed in")

        let named = try await RNLogin.offsider("credential status \(Users.admin.name) --app \(Users.app) --json")
        #expect(named.exitCode == 0, "\(named.stderr)")
        #expect(RNLogin.username(in: try RNLogin.object(named, "credential status \(Users.admin.name)")) == Users.admin.username)
    }

    @Test("login --where role=admin signs the admin in, status shows it here, and signed-out clears it after a sign-out in the app", arguments: RNPlatform.enabled)
    func whereSignsInAndRecords(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)

        let report = try await RNLogin.signIn(app, "--where role=admin")
        #expect(report["version"] as? Int == 1)
        #expect(report["app"] as? String == Users.app)
        #expect(report["name"] as? String == Users.admin.name)
        #expect(report["tags"] as? [String] == Users.admin.tags)
        #expect(report["where"] as? [String] == ["role=admin"])
        #expect(report["identity"] as? String == "filled")
        #expect(report["password"] as? String == "filled")
        #expect(report["submitted"] as? Bool == true)
        try await RNLogin.expectSignedIn(app, as: Users.admin, signIns: 1)

        let signedIn = try await RNLogin.status(on: app)
        #expect(RNLogin.signedInHere(signedIn) == Users.admin.name)
        let record = try #require(RNLogin.records(of: Users.admin.name, on: platform, in: signedIn).first)
        #expect(record["since"] is String)
        #expect(record["restarted"] as? Bool != true)
        #expect(RNLogin.records(of: Users.member.name, on: platform, in: signedIn).isEmpty)

        try await RNLogin.signOutInApp(app)
        let cleared = try await RNLogin.signedOut(app)
        #expect(cleared.stdout.contains(Users.admin.name), "signed-out names who it cleared: \(cleared.stdout)")
        let after = try await RNLogin.status(on: app)
        #expect(RNLogin.signedInHere(after) == nil)
        #expect(RNLogin.records(of: Users.admin.name, on: platform, in: after).isEmpty)
    }

    @Test("login --where with no matching user exits 2 with user_not_found and types nothing", arguments: RNPlatform.enabled)
    func noMatchTypesNothing(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)

        let output = try await app.offsider("login --where role=owner --json")
        #expect(output.exitCode == 2, "\(output.stderr)")
        RNLogin.expectNoSecrets(output, "login --where role=owner")
        let error = try RNLogin.error(output)
        #expect(error["reason"] as? String == "user_not_found")
        #expect(error["dispatched"] as? String != "yes")
        try await RNLogin.expectNothingTyped(app)
        #expect(RNLogin.signedInHere(try await RNLogin.status(on: app)) == nil)

        let dryRun = try await RNLogin.offsider("credential status --where role=owner --app \(Users.app) --json")
        #expect(dryRun.exitCode == 2, "\(dryRun.stderr)")
    }

    @Test("login --where matching several users exits 6 with user_ambiguous, lists names, tags and notes, and types nothing", arguments: RNPlatform.enabled)
    func severalMatchesListUsers(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)

        let output = try await app.offsider("login --where env=e2e --json")
        #expect(output.exitCode == 6, "\(output.stderr)")
        RNLogin.expectNoSecrets(output, "login --where env=e2e")
        let error = try RNLogin.error(output)
        #expect(error["reason"] as? String == "user_ambiguous")
        let listed = error["users"] as? [[String: Any]] ?? []
        #expect(listed.compactMap { $0["name"] as? String }.sorted() == [Users.admin.name, Users.member.name])
        for entry in listed {
            #expect(entry["tags"] is [String], "\(entry)")
            #expect(entry["about"] is String, "\(entry)")
            #expect(entry["username"] == nil, "\(entry)")
        }
        try await RNLogin.expectNothingTyped(app)

        let dryRun = try await RNLogin.offsider("credential status --where env=e2e --app \(Users.app) --json")
        #expect(dryRun.exitCode == 6, "\(dryRun.stderr)")
        let narrowed = try await RNLogin.offsider("credential status --where env=e2e --where role=member --app \(Users.app) --json")
        #expect(narrowed.exitCode == 0, "\(narrowed.stderr)")
        RNLogin.expectNoSecrets(narrowed, "credential status --where env=e2e --where role=member")
        #expect(RNLogin.names(in: try RNLogin.object(narrowed, "credential status --where")) == [Users.member.name])
    }

    @Test("switching from the admin to the member after a sign-out in the app moves this device's record to the member", arguments: RNPlatform.enabled)
    func switchMovesRecord(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)
        try await RNLogin.signIn(app, Users.admin.name)
        try await RNLogin.expectSignedIn(app, as: Users.admin, signIns: 1)
        #expect(RNLogin.signedInHere(try await RNLogin.status(on: app)) == Users.admin.name)

        try await RNLogin.signOutInApp(app)
        let switched = try await RNLogin.signIn(app, "--where credit")
        #expect(switched["name"] as? String == Users.member.name)
        try await RNLogin.expectSignedIn(app, as: Users.member, signIns: 2)

        let status = try await RNLogin.status(on: app)
        #expect(RNLogin.signedInHere(status) == Users.member.name)
        #expect(RNLogin.records(of: Users.member.name, on: platform, in: status).count == 1)
        #expect(RNLogin.records(of: Users.admin.name, on: platform, in: status).isEmpty)

        try await RNLogin.signOutInApp(app)
        try await RNLogin.signedOut(app)
    }

    @Test("a describe that drops the credit tag makes --where credit exit 2 until the tag is back", arguments: RNPlatform.enabled)
    func driftChangesSelection(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)
        let drained = "Store credit used up"
        try await RNLogin.describe(Users.member.name, "--untag credit --state \(AndroidE2E.quote(drained))")
        do {
            let listed = try #require(RNLogin.user(Users.member.name, in: try await RNLogin.status()))
            #expect(listed["tags"] as? [String] == ["env=e2e", "role=member"])
            #expect(listed["state"] as? String == drained)
            #expect(listed["updated"] is String)

            let output = try await app.offsider("login --where credit --json")
            #expect(output.exitCode == 2, "\(output.stderr)")
            #expect(try RNLogin.error(output)["reason"] as? String == "user_not_found")
            try await RNLogin.expectNothingTyped(app)
        } catch {
            try? await RNLogin.restoreMember()
            throw error
        }
        try await RNLogin.restoreMember()

        let restored = try await RNLogin.offsider("credential status --where credit --app \(Users.app) --json")
        #expect(restored.exitCode == 0, "\(restored.stderr)")
        #expect(RNLogin.names(in: try RNLogin.object(restored, "credential status --where credit")) == [Users.member.name])
    }

    @Test("after the app relaunches signed out, status still names the last user until signed-out clears it", arguments: RNPlatform.enabled)
    func recordOutlivesRelaunch(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)
        try await RNLogin.signIn(app, Users.admin.name)
        try await RNLogin.expectSignedIn(app, as: Users.admin, signIns: 1)

        try await app.open(RNLogin.screen)
        _ = try await app.waitForLabel(of: "user-switch-test-state") { $0 == "Session: Signed out" }
        #expect(try await app.label(of: "user-switch-test-sign-ins") == "Sign-ins: 0")

        let kept = try await RNLogin.status(on: app)
        #expect(RNLogin.signedInHere(kept) == Users.admin.name)
        let record = try #require(RNLogin.records(of: Users.admin.name, on: platform, in: kept).first)
        #expect(record["restarted"] as? Bool != true, "an app relaunch is not a device restart")

        let cleared = try await RNLogin.signedOut(app)
        #expect(cleared.stdout.contains(Users.admin.name), "signed-out names who it cleared: \(cleared.stdout)")
        #expect(RNLogin.signedInHere(try await RNLogin.status(on: app)) == nil)
        let again = try await RNLogin.signedOut(app)
        #expect(!again.stdout.contains(Users.admin.name), "nothing was left to clear: \(again.stdout)")
    }

    @Test("while a user is signed in, login finds no form, exits 2, and names who Offsider signed in and how to switch", arguments: RNPlatform.enabled)
    func signedInLoginNamesLastUser(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)
        try await RNLogin.signIn(app, Users.admin.name)
        try await RNLogin.expectSignedIn(app, as: Users.admin, signIns: 1)

        let output = try await app.offsider("login \(Users.member.name) --json")
        #expect(output.exitCode == 2, "\(output.stderr)")
        RNLogin.expectNoSecrets(output, "login \(Users.member.name)")
        let error = try RNLogin.error(output)
        #expect(error["reason"] as? String == "selector_not_found")
        let message = error["message"] as? String ?? ""
        #expect(message.contains(Users.admin.name), "\(message)")
        #expect((message + " " + (error["hint"] as? String ?? "")).contains("credential signed-out"), "\(message)")
        #expect(try await app.label(of: "user-switch-test-current") == "Signed in as \(Users.admin.username)")
        #expect(RNLogin.signedInHere(try await RNLogin.status(on: app)) == Users.admin.name)

        try await RNLogin.signOutInApp(app)
        try await RNLogin.signedOut(app)
    }

    @Test("a refused account still exits 0, because exit 0 is the tap, and the screen shows the refusal", arguments: RNPlatform.enabled)
    func refusedStillTaps(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await RNLogin.fresh(app)

        let report = try await RNLogin.signIn(app, "--where state=refused")
        #expect(report["name"] as? String == Users.refused.name)
        _ = try await app.waitForLabel(of: "user-switch-test-state") { $0 == "Session: Refused" }
        #expect(try await app.label(of: "user-switch-test-error") == "This account cannot sign in")
        #expect(try await app.label(of: "user-switch-test-sign-ins") == "Sign-ins: 0")
        try await RNLogin.signedOut(app)
    }
}

/// The users the login suite saves for the playground; every username and password is made up.
enum RNLoginUsers {
    struct User: Sendable {
        let name: String
        let username: String
        let password: String
        let tags: [String]
        let about: String
        let avoid: String
        let state: String
    }

    static let app = IOSRNPlayground.bundleID

    static let admin = User(
        name: "e2e-admin", username: "e2e-admin@example.com", password: "Fixture-admin-41",
        tags: ["env=e2e", "role=admin"],
        about: "Admin on the playground, can approve requests", avoid: "Tests that need a member view", state: "No open requests"
    )
    static let member = User(
        name: "e2e-member", username: "e2e-member@example.com", password: "Fixture-member-52",
        tags: ["credit", "env=e2e", "role=member"],
        about: "Member with store credit", avoid: "Admin screens", state: "Store credit available"
    )
    static let refused = User(
        name: "e2e-refused", username: "refused-e2e@example.com", password: "Fixture-refused-63",
        tags: ["state=refused"],
        about: "An account the playground refuses", avoid: "Any test that needs a signed-in user", state: "Locked"
    )

    static let all = [admin, member, refused]
}

/// Commands and checks for the login suite, on the user switch screen.
enum RNLogin {
    static let screen = "user-switch-test"

    /// Runs offsider with no device, so status reports no signedInHere.
    static func offsider(_ arguments: String) async throws -> SeparatedCommandOutput {
        try await TestHelpers.runOffsiderCommandSeparated(arguments)
    }

    static func object(_ output: SeparatedCommandOutput, _ what: String) throws -> [String: Any] {
        let line = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            throw DescribeUIError(description: "\(what) exited \(output.exitCode) with no JSON object on stdout: \(output.stdout) \(output.stderr)")
        }
        return object
    }

    static func error(_ output: SeparatedCommandOutput) throws -> [String: Any] {
        let envelope = try object(output, "the failed command")
        #expect(envelope["ok"] as? Bool == false)
        return try #require(envelope["error"] as? [String: Any])
    }

    /// `credential status --json` for the playground; on `app`'s device when given, so it reports signedInHere.
    static func status(on app: RNApp? = nil) async throws -> [String: Any] {
        let arguments = "credential status --app \(RNLoginUsers.app) --json"
        let output: SeparatedCommandOutput
        if let app {
            output = try await app.offsider(arguments)
        } else {
            output = try await offsider(arguments)
        }
        guard output.exitCode == 0 else {
            throw DescribeUIError(description: "\(arguments) exited \(output.exitCode): \(output.stderr)")
        }
        return try object(output, arguments)
    }

    static func users(_ report: [String: Any]) -> [[String: Any]] {
        report["users"] as? [[String: Any]] ?? []
    }

    /// The users a status report lists, or the one user it prints on its own.
    static func names(in report: [String: Any]) -> [String] {
        let listed = users(report).compactMap { $0["name"] as? String }
        return listed.isEmpty ? [report["name"] as? String].compactMap { $0 } : listed
    }

    static func user(_ name: String, in report: [String: Any]) -> [String: Any]? {
        users(report).first { $0["name"] as? String == name }
    }

    static func username(in report: [String: Any]) -> String? {
        report["username"] as? String ?? users(report).first?["username"] as? String
    }

    static func signedInHere(_ report: [String: Any]) -> String? {
        report["signedInHere"] as? String
    }

    /// The user's sign-in records on this platform's device; each run drives one device per platform.
    static func records(of name: String, on platform: RNPlatform, in report: [String: Any]) -> [[String: Any]] {
        (user(name, in: report)?["signedIn"] as? [[String: Any]] ?? []).filter { $0["platform"] as? String == platform.rawValue }
    }

    static func expectNoSecrets(_ output: SeparatedCommandOutput, _ what: String) {
        let printed = output.stdout + output.stderr
        #expect(!printed.contains("@example.com"), "\(what) printed a username: \(printed)")
        for user in RNLoginUsers.all {
            #expect(!printed.contains(user.password), "\(what) printed a password")
        }
    }

    /// Relaunches the screen, which signs the app out, and clears any sign-in recorded on this device.
    static func fresh(_ app: RNApp) async throws {
        try await app.open(screen)
        try await signedOut(app)
        _ = try await app.waitForLabel(of: "user-switch-test-state") { $0 == "Session: Signed out" }
    }

    /// `login <selection> --json` that must exit 0; returns its report.
    @discardableResult
    static func signIn(_ app: RNApp, _ selection: String) async throws -> [String: Any] {
        let output = try await app.offsider("login \(selection) --json")
        guard output.exitCode == 0 else {
            throw DescribeUIError(description: "login \(selection) on \(app.platform.rawValue) exited \(output.exitCode): \(output.stderr)")
        }
        expectNoSecrets(output, "login \(selection)")
        return try object(output, "login \(selection)")
    }

    static func expectSignedIn(_ app: RNApp, as user: RNLoginUsers.User, signIns: Int) async throws {
        _ = try await app.waitForLabel(of: "user-switch-test-state") { $0 == "Session: Signed in" }
        #expect(try await app.label(of: "user-switch-test-current") == "Signed in as \(user.username)")
        #expect(try await app.label(of: "user-switch-test-sign-ins") == "Sign-ins: \(signIns)")
    }

    /// The email and password fields are still empty and the app never left signed out.
    static func expectNothingTyped(_ app: RNApp) async throws {
        let tree = try await app.tree()
        for id in ["user-switch-test-email", "user-switch-test-password"] {
            let field = try #require(DescribeUITree.node(id: id, in: tree), "\(id) left the screen")
            #expect((field["value"] as? String ?? "").isEmpty, "\(id) holds typed text")
        }
        #expect(DescribeUITree.node(id: "user-switch-test-state", in: tree)?["label"] as? String == "Session: Signed out")
    }

    static func signOutInApp(_ app: RNApp) async throws {
        try await app.run("tap --id user-switch-test-sign-out --verify-id user-switch-test-email --retries 2")
        _ = try await app.waitForLabel(of: "user-switch-test-state") { $0 == "Session: Signed out" }
    }

    @discardableResult
    static func signedOut(_ app: RNApp) async throws -> SeparatedCommandOutput {
        try await app.run("credential signed-out --app \(RNLoginUsers.app) --json")
    }

    static func describe(_ name: String, _ changes: String) async throws {
        let arguments = "credential describe \(name) --app \(RNLoginUsers.app) \(changes) --json"
        let output = try await offsider(arguments)
        guard output.exitCode == 0 else {
            throw DescribeUIError(description: "\(arguments) exited \(output.exitCode): \(output.stderr)")
        }
    }

    static func restoreMember() async throws {
        try await describe(RNLoginUsers.member.name, "--tag credit --state \(AndroidE2E.quote(RNLoginUsers.member.state))")
    }

    /// Fails before anything is saved when the playground already has users: deleting them could raise a Keychain prompt.
    static func refuseSavedUsers() async throws {
        let report = try await status()
        guard report["version"] as? Int == 2 else {
            throw DescribeUIError(description: "credential status printed version \(report["version"] ?? "none"); the login suite needs the version 2 list.")
        }
        let saved = names(in: report)
        guard saved.isEmpty else {
            let commands = saved.map { "  offsider credential remove \($0) --app \(RNLoginUsers.app)" }.joined(separator: "\n")
            throw DescribeUIError(description: """
                The React Native playground already has saved users (\(saved.joined(separator: ", "))), so the login suite did not start. \
                It never removes users it did not save. Check them, then remove them with the build that saved them:
                \(commands)
                """)
        }
    }

    /// Saves each user from two lines of stdin, then writes its notes with describe.
    static func saveUsers() async throws {
        let binary = AndroidE2E.quote(try TestHelpers.getOffsiderPath())
        for user in RNLoginUsers.all {
            let lines = "printf '%s\\n%s\\n' \(AndroidE2E.quote(user.username)) \(AndroidE2E.quote(user.password))"
            let tags = user.tags.map { "--tag \($0)" }.joined(separator: " ")
            let saved = try await CommandRunner.runSeparated("\(lines) | \(binary) credential set \(user.name) --stdin --app \(RNLoginUsers.app) \(tags) --json", timeout: 60)
            guard saved.exitCode == 0 else {
                throw DescribeUIError(description: "credential set \(user.name) exited \(saved.exitCode): \(saved.stderr)")
            }
            let notes = [("--about", user.about), ("--avoid", user.avoid), ("--state", user.state)]
            try await describe(user.name, notes.map { "\($0.0) \(AndroidE2E.quote($0.1))" }.joined(separator: " "))
        }
    }

    /// Removes the suite's users and every enabled device's record; returns what is left over.
    static func cleanUp() async -> [String] {
        var problems: [String] = []
        var removals: [String: String] = [:]
        for user in RNLoginUsers.all {
            let output = try? await offsider("credential remove \(user.name) --app \(RNLoginUsers.app) --json")
            removals[user.name] = output.map { "exit \($0.exitCode): \($0.stderr)" } ?? "did not run"
        }
        for platform in RNPlatform.enabled {
            do {
                try await signedOut(RNApp(platform))
            } catch {
                problems.append("signed-out on \(platform.rawValue): \(error)")
            }
        }
        do {
            for name in names(in: try await status()) {
                problems.append("\(name) is still saved (remove: \(removals[name] ?? "not one of the suite's users"))")
            }
        } catch {
            problems.append("credential status after clean-up: \(error)")
        }
        return problems
    }
}

/// Around the login suite: refuses to start beside saved users, saves its own, and always removes them and their records.
struct SavedUsersScope: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard RNPlatform.anyEnabled else {
            try await function()
            return
        }
        try await RNLogin.refuseSavedUsers()
        var failure: (any Error)?
        do {
            try await RNLogin.saveUsers()
            try await function()
        } catch {
            failure = error
        }
        let problems = await RNLogin.cleanUp()
        switch (failure, problems.isEmpty) {
        case (let failure?, true):
            throw failure
        case (let failure?, false):
            throw DescribeUIError(description: "\(failure)\nClean-up also failed: \(problems.joined(separator: "; "))")
        case (nil, false):
            throw DescribeUIError(description: "Clean-up failed: \(problems.joined(separator: "; "))")
        case (nil, true):
            return
        }
    }
}
