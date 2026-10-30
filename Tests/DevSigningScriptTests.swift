import Foundation
import OffsiderCore
import Testing

/// `scripts/build.sh dev-sign`, in a copy of the scripts with stand-ins for the tools, so nothing here reads this Mac's keychain or signs anything.
@Suite("Debug signing step")
struct DevSigningScriptTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let development = "Apple Development: Test Dev (AAAAAAAAAA)"
    static let release = "Developer ID Application: Test Dev (BBBBBBBBBB)"
    static let developmentHash = String(repeating: "A", count: 40)
    static let releaseHash = String(repeating: "B", count: 40)
    static let identities = [(developmentHash, development), (releaseHash, release)]

    struct Sandbox {
        let folder: URL

        var tools: URL { folder.appendingPathComponent("tools") }
        var binaries: URL { folder.appendingPathComponent("bin") }
        var signed: [String] { Self.lines(folder.appendingPathComponent("codesign.log")) }
        var swiftCalls: [String] { Self.lines(folder.appendingPathComponent("swift.log")) }

        static func lines(_ file: URL) -> [String] {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func file(_ name: String, _ text: String, executable: Bool = false) throws {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }

        func run(_ arguments: String..., in checkout: URL? = nil, environment extra: [String: String] = [:]) async throws -> ProcessCaptureResult {
            var environment = ProcessInfo.processInfo.environment
            for key in ["OFFSIDER_DEV_SIGNING_IDENTITY", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"] { environment.removeValue(forKey: key) }
            environment["PATH"] = "\(tools.path):/usr/bin:/bin"
            environment["OFFSIDER_OUTPUT"] = "agent"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment.merge(extra) { $1 }
            let script = (checkout ?? folder).appendingPathComponent("scripts/build.sh").path
            return try await ProcessCapture.run(executable: "/bin/bash", arguments: [script, "dev-sign"] + arguments, environment: environment, timeout: 30)
        }
    }

    static func sandbox(identities: [(String, String)] = identities) throws -> Sandbox {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-dev-sign-\(UUID().uuidString)").resolvingSymlinksInPath()
        let sandbox = Sandbox(folder: folder)
        try sandbox.file("scripts/build.sh", String(contentsOf: root.appendingPathComponent("scripts/build.sh"), encoding: .utf8))
        try sandbox.file("scripts/lib/ui.sh", String(contentsOf: root.appendingPathComponent("scripts/lib/ui.sh"), encoding: .utf8))
        let rows = identities.enumerated().map { "  \($0.offset + 1)) \($0.element.0) \"\($0.element.1)\"" }.joined(separator: "\n")
        try sandbox.file("tools/security", "#!/bin/bash\ncat <<'ROWS'\n\(rows)\n     \(identities.count) valid identities found\nROWS\n", executable: true)
        try sandbox.file("tools/codesign", "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(folder.path)/codesign.log'\n", executable: true)
        try sandbox.file("tools/swift", "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(folder.path)/swift.log'\nprintf '%s\\n' '\(folder.path)/bin'\n", executable: true)
        try sandbox.file("bin/offsider", "#!/bin/bash\nexit 0\n", executable: true)
        return sandbox
    }

    @Test("off by default: with nothing named, make build's call signs nothing and says nothing")
    func offByDefault() async throws {
        let sandbox = try Self.sandbox()
        let result = try await sandbox.run("--if-set")
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(sandbox.signed.isEmpty)
    }

    @Test("asked directly with nothing named, it fails and says what to add")
    func askedDirectlyWithNothingNamed() async throws {
        let sandbox = try Self.sandbox()
        let result = try await sandbox.run()
        #expect(result.status != 0)
        #expect(result.stderr.contains("OFFSIDER_DEV_SIGNING_IDENTITY is not set"))
        #expect(result.stderr.contains(".env.example"))
        #expect(sandbox.signed.isEmpty)
    }

    @Test("an identity missing from this Mac names the command that lists them, even from make build")
    func missingIdentity() async throws {
        let sandbox = try Self.sandbox()
        let result = try await sandbox.run("--if-set", environment: ["OFFSIDER_DEV_SIGNING_IDENTITY": "Apple Development: Nobody (CCCCCCCCCC)"])
        #expect(result.status != 0)
        #expect(result.stderr.contains("no valid signing identity"))
        #expect(result.stderr.contains("security find-identity -v -p codesigning"))
        #expect(sandbox.signed.isEmpty)
    }

    @Test("part of a name is not a match")
    func partOfANameIsNotAMatch() async throws {
        let sandbox = try Self.sandbox()
        let result = try await sandbox.run(environment: ["OFFSIDER_DEV_SIGNING_IDENTITY": "Apple Development"])
        #expect(result.status != 0)
        #expect(sandbox.signed.isEmpty)
    }

    @Test("a Developer ID identity is refused, by name and by hash, so a debug build never carries a release's signature")
    func developerIDRefused() async throws {
        for named in [Self.release, Self.releaseHash] {
            let sandbox = try Self.sandbox()
            let result = try await sandbox.run(environment: ["OFFSIDER_DEV_SIGNING_IDENTITY": named])
            #expect(result.status != 0)
            #expect(result.stderr.contains("Apple Development identity only"))
            #expect(sandbox.signed.isEmpty)
        }
    }

    @Test("two identities with one name ask for the hash")
    func ambiguousName() async throws {
        let sandbox = try Self.sandbox(identities: [(Self.developmentHash, Self.development), (String(repeating: "C", count: 40), Self.development)])
        let result = try await sandbox.run(environment: ["OFFSIDER_DEV_SIGNING_IDENTITY": Self.development])
        #expect(result.status != 0)
        #expect(result.stderr.contains("40-character hash"))
        #expect(sandbox.signed.isEmpty)
    }

    @Test("an Apple Development identity signs the executable alone: hardened, offline, as the debug identifier, never --deep")
    func signsTheExecutable() async throws {
        let sandbox = try Self.sandbox()
        let result = try await sandbox.run(environment: ["OFFSIDER_DEV_SIGNING_IDENTITY": Self.development])
        #expect(result.status == 0, "\(result.stderr)")
        let call = try #require(sandbox.signed.first)
        #expect(sandbox.signed.count == 1)
        #expect(call.contains("--sign \(Self.developmentHash)"))
        #expect(call.contains("--options runtime"))
        #expect(call.contains("--timestamp=none"))
        #expect(call.contains("--identifier com.mpalmes.offsider.dev"))
        #expect(call.hasSuffix("\(sandbox.binaries.path)/offsider"))
        #expect(!call.contains("--deep"))
    }

    @Test("a signed build that does not start fails the step, with no dyld error left to read later")
    func smokeTest() async throws {
        let sandbox = try Self.sandbox()
        try sandbox.file("bin/offsider", "#!/bin/bash\nexit 134\n", executable: true)
        let result = try await sandbox.run(environment: ["OFFSIDER_DEV_SIGNING_IDENTITY": Self.development])
        #expect(result.status != 0)
        #expect(result.stderr.contains("does not start"))
    }

    @Test("a .env is read for its one key and never run")
    func envFileIsNeverRun() async throws {
        let sandbox = try Self.sandbox()
        let ran = sandbox.folder.appendingPathComponent("ran").path
        try sandbox.file(".env", "touch '\(ran)'\nOTHER=$(touch '\(ran)')\nOFFSIDER_DEV_SIGNING_IDENTITY=\"\(Self.development)\"  \n")
        let result = try await sandbox.run()
        #expect(result.status == 0, "\(result.stderr)")
        #expect(sandbox.signed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: ran))
    }

    @Test("--scratch-path reaches swift, so a build in its own folder signs there")
    func scratchPath() async throws {
        let sandbox = try Self.sandbox()
        let result = try await sandbox.run("--scratch-path", "/tmp/elsewhere", environment: ["OFFSIDER_DEV_SIGNING_IDENTITY": Self.development])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(sandbox.swiftCalls.contains { $0.contains("--scratch-path /tmp/elsewhere") && $0.contains("--show-bin-path") })
    }

    @Test("a worktree, which has no .env of its own, reads the main checkout's")
    func worktreeReadsMainCheckout() async throws {
        let sandbox = try Self.sandbox()
        try sandbox.file(".gitignore", ".env\ntools/\nbin/\n*.log\n")
        try sandbox.file(".env", "OFFSIDER_DEV_SIGNING_IDENTITY=\(Self.development)\n")
        func git(_ arguments: String...) async throws {
            let result = try await ProcessCapture.run(
                executable: "/usr/bin/git",
                arguments: ["-C", sandbox.folder.path, "-c", "user.name=Offsider Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments,
                environment: ProcessInfo.processInfo.environment.merging(["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { $1 },
                timeout: 30
            )
            #expect(result.status == 0, "\(result.stderr)")
        }
        try await git("init", "-q")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "first")
        let worktree = sandbox.folder.appendingPathComponent("linked")
        try await git("worktree", "add", "-q", worktree.path)
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".env").path))

        let result = try await sandbox.run(in: worktree)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(sandbox.signed.count == 1)
    }
}
