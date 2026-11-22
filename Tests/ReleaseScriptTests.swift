import CryptoKit
import Foundation
import Testing

@Suite("Release script")
struct ReleaseScriptTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = root.appendingPathComponent("scripts/release.sh")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private static func payloadDirectory() throws -> (dist: URL, payload: Data) {
        let dist = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        let payload = Data("not a payload".utf8)
        try payload.write(to: dist.appendingPathComponent("offsider-0.0.0-arm64-unsigned.tar.gz"))
        return (dist, payload)
    }

    @Test("unpack-payload refuses a payload whose digest differs from the one the build job recorded, before unpacking")
    func unpackPayloadRefusesDigestMismatch() throws {
        let (dist, _) = try Self.payloadDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        let wrong = String(repeating: "0", count: 64)
        let result = try Self.run(["unpack-payload", "--version", "0.0.0", "--dist", dist.path, "--sha256", wrong])
        #expect(result.status == 1)
        #expect(result.stderr.contains("payload digest mismatch"))
        #expect(!FileManager.default.fileExists(atPath: dist.appendingPathComponent("offsider-0.0.0-arm64").path))
    }

    @Test("unpack-payload accepts the recorded digest and only then unpacks")
    func unpackPayloadAcceptsMatchingDigest() throws {
        let (dist, payload) = try Self.payloadDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let result = try Self.run(["unpack-payload", "--version", "0.0.0", "--dist", dist.path, "--sha256", digest])
        #expect(result.stderr.contains("payload digest matches"))
        #expect(!result.stderr.contains("digest mismatch"))
    }

    @Test("unpack-payload refuses a digest that is not 64 hex characters without reading the payload")
    func unpackPayloadRefusesMalformedDigest() throws {
        let (dist, _) = try Self.payloadDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        let result = try Self.run(["unpack-payload", "--version", "0.0.0", "--dist", dist.path, "--sha256", "abc"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("64 lowercase hex"))
    }

    /// A payload tarball of `entries` made by bsdtar in a fresh folder, with its digest; `rename` rewrites every name as tar's `-s` does.
    private static func craftedPayload(rename: String? = nil, absoluteNames: Bool = false, _ entries: (URL) throws -> [String]) throws -> (dist: URL, digest: String) {
        let dist = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-release-\(UUID().uuidString)")
        let source = dist.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let names = try entries(source)
        let tarball = dist.appendingPathComponent("offsider-0.0.0-arm64-unsigned.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", tarball.path] + (absoluteNames ? ["-P"] : []) + (rename.map { ["-s", $0] } ?? []) + ["-C", source.path] + names
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let digest = SHA256.hash(data: try Data(contentsOf: tarball)).map { String(format: "%02x", $0) }.joined()
        return (dist, digest)
    }

    private static func touch(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static let unsafePayloads: [(String, String)] = [
        ("absolute", "absolute path"), ("dotdot", "path with .."), ("absolute-link", "link to an absolute path"), ("dotdot-link", "link with .."),
        ("hard-link", "not a plain file, folder or link"), ("fifo", "not a plain file, folder or link"), ("huge", "unpacks to more than"),
    ]

    @Test("unpack-payload lists the payload first and unpacks nothing with an absolute path, .., a link out, a hard link, a FIFO or over the size cap", arguments: unsafePayloads)
    func unpackPayloadRefusesUnsafeEntries(kind: String, message: String) throws {
        let (dist, digest) = try Self.craftedPayload(rename: kind == "absolute" ? "|^|/tmp/offsider-vet-|" : kind == "dotdot" ? "|^|../|" : nil, absoluteNames: kind == "absolute") { source in
            switch kind {
            case "absolute", "dotdot":
                try Self.touch(source.appendingPathComponent("escape"))
                return ["escape"]
            case "absolute-link":
                try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("hosts").path, withDestinationPath: "/etc/hosts")
                return ["hosts"]
            case "dotdot-link":
                try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("up").path, withDestinationPath: "../outside")
                return ["up"]
            case "hard-link":
                try Self.touch(source.appendingPathComponent("a"))
                try FileManager.default.linkItem(at: source.appendingPathComponent("a"), to: source.appendingPathComponent("b"))
                return ["a", "b"]
            case "fifo":
                #expect(mkfifo(source.appendingPathComponent("pipe").path, 0o600) == 0)
                return ["pipe"]
            default:
                let big = source.appendingPathComponent("big")
                FileManager.default.createFile(atPath: big.path, contents: nil)
                let handle = try FileHandle(forWritingTo: big)
                try handle.truncate(atOffset: 2 << 30)
                try handle.close()
                return ["big"]
            }
        }
        defer { try? FileManager.default.removeItem(at: dist) }
        let result = try Self.run(["unpack-payload", "--version", "0.0.0", "--dist", dist.path, "--sha256", digest])
        #expect(result.status == 1)
        #expect(result.stderr.contains(message), "\(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: dist.appendingPathComponent("offsider-0.0.0-arm64").path))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/offsider-vet-escape"))
    }

    @Test("a payload of plain files, folders and links inside the tree, as a framework has, passes the listing and is unpacked")
    func unpackPayloadAcceptsFrameworkLinks() throws {
        let (dist, digest) = try Self.craftedPayload { source in
            let framework = source.appendingPathComponent("Frameworks/Example.framework")
            try Self.touch(framework.appendingPathComponent("Versions/A/Example"))
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Example").path, withDestinationPath: "Versions/Current/Example")
            return ["Frameworks"]
        }
        defer { try? FileManager.default.removeItem(at: dist) }
        let result = try Self.run(["unpack-payload", "--version", "0.0.0", "--dist", dist.path, "--sha256", digest])
        #expect(!result.stderr.contains("cannot be listed") && !result.stderr.contains("not a plain file") && !result.stderr.contains("link"), "\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: dist.appendingPathComponent("offsider-0.0.0-arm64/Frameworks/Example.framework/Versions/A/Example").path))
    }

    @Test("release builds carry no entitlements, so library validation stays on; ad-hoc builds carry the opt-out")
    func entitlementFiles() throws {
        let release = try Self.plist("entitlements.plist")
        let adhoc = try Self.plist("entitlements-adhoc.plist")
        #expect(release.isEmpty)
        #expect(adhoc["com.apple.security.cs.disable-library-validation"] as? Bool == true)
    }

    @Test("a release run refuses an entitlements file that disables library validation before doing anything")
    func releaseRefusesLibraryValidationOptOut() throws {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/release.sh")
        process.arguments = ["stage", "--version", "0.0.0"]
        var environment = ProcessInfo.processInfo.environment
        environment["ENTITLEMENTS"] = Self.root.appendingPathComponent("entitlements-adhoc.plist").path
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 1)
        #expect(output.contains("release builds keep library validation on"))
        #expect(!output.contains("missing"))
    }

    /// A throwaway repository holding a copy of release.sh, tagged `v1.2.3`, with nothing built.
    private static func taggedRepository() throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-release-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/release.sh"), to: repo.appendingPathComponent("scripts/release.sh"))
        try Data("readme\n".utf8).write(to: repo.appendingPathComponent("README"))
        for arguments in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@localhost", "-c", "commit.gpgsign=false", "commit", "-qm", "x"], ["-c", "tag.gpgsign=false", "tag", "v1.2.3"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", repo.path] + arguments
            git.standardOutput = Pipe()
            git.standardError = Pipe()
            try git.run()
            git.waitUntilExit()
            #expect(git.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        }
        return repo
    }

    private static func run(script: URL, _ arguments: [String], unsetting: [String] = [], setting: [String: String] = [:]) throws -> (status: Int32, stderr: String, stdout: String) {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for name in unsetting { environment.removeValue(forKey: name) }
        environment.merge(setting) { _, new in new }
        process.environment = environment
        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout
        try process.run()
        let printed = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output, printed)
    }

    @Test("rehearse --adhoc with no --version takes git describe's without the v, keeping -dirty; other commands still need it")
    func rehearseDerivesVersion() throws {
        let repo = try Self.taggedRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let script = repo.appendingPathComponent("scripts/release.sh")
        let clean = try Self.run(script: script, ["rehearse", "--adhoc", "--dist", repo.appendingPathComponent("dist").path])
        #expect(clean.stderr.contains("rehearse: using version 1.2.3 from git describe"))
        #expect(!clean.stderr.contains("--version is required"))
        try Data("changed\n".utf8).write(to: repo.appendingPathComponent("README"))
        let dirty = try Self.run(script: script, ["rehearse", "--adhoc", "--dist", repo.appendingPathComponent("dist").path])
        #expect(dirty.stderr.contains("rehearse: using version 1.2.3-dirty from git describe"))
        let stage = try Self.run(script: script, ["stage"])
        #expect(stage.status == 1)
        #expect(stage.stderr.contains("--version is required"))
    }

    @Test("a signed rehearse with nothing set names every missing variable in one error before any work")
    func rehearseListsMissingVariables() throws {
        let repo = try Self.taggedRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let names = ["OFFSIDER_SIGNING_IDENTITY", "OFFSIDER_NOTARY_KEY_PATH", "OFFSIDER_NOTARY_KEY_ID", "OFFSIDER_NOTARY_ISSUER_ID", "TEAM_ID"]
        let result = try Self.run(script: repo.appendingPathComponent("scripts/release.sh"), ["rehearse", "--version", "1.2.3"], unsetting: names)
        #expect(result.status == 1)
        #expect(result.stderr.contains("rehearse needs these set: " + names.joined(separator: " ")))
        #expect(result.stderr.split(separator: "\n").filter { $0.hasPrefix("Try: ") }.count == 1)
        #expect(!result.stderr.contains("staged"))
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("dist").path))
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("record writes the build record, the SBOM for that version and a copy of SECURITY.md")
    func recordWritesTheProofFiles() throws {
        let dist = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-release-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dist) }
        let result = try Self.run(["record", "--version", "0.0.0", "--dist", dist.path])
        #expect(result.status == 0, "\(result.stderr)")

        let info = try String(contentsOf: dist.appendingPathComponent("build-info.txt"), encoding: .utf8)
        let keys = info.split(separator: "\n").map { String($0.prefix { $0 != "=" }) }
        #expect(keys == ["version", "commit", "workflow_ref", "run_id", "run_attempt", "runner_environment", "runner_labels", "runner_image", "macos", "xcode", "swift", "idb", "helper_dex_sha256"])
        #expect(info.contains("version=0.0.0\n"))
        #expect(info.contains("helper_dex_sha256=\(try Self.sha256(Self.root.appendingPathComponent("Sources/Offsider/Resources/helper/offsider-helper.dex")))\n"))
        #expect(!info.split(separator: "\n").contains { $0.hasSuffix("=") })

        let sbom = try JSONSerialization.jsonObject(with: Data(contentsOf: dist.appendingPathComponent("offsider-0.0.0.cdx.json"))) as? [String: Any]
        let component = (sbom?["metadata"] as? [String: Any])?["component"] as? [String: Any]
        #expect(component?["version"] as? String == "0.0.0")
        #expect(try Data(contentsOf: dist.appendingPathComponent("SECURITY.md")) == Data(contentsOf: Self.root.appendingPathComponent("SECURITY.md")))
    }

    @Test("record writes beside the archive, where package looks for the files and writes SHA256SUMS")
    func recordFollowsTheArchive() throws {
        let dist = try Self.stagedDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        let out = dist.appendingPathComponent("out")
        let arguments = ["--version", "0.0.0", "--dist", dist.path, "--archive", out.appendingPathComponent("offsider-0.0.0-arm64.tar.gz").path]
        #expect(try Self.run(["record"] + arguments).status == 0)
        let packaged = try Self.run(["package"] + arguments)
        #expect(packaged.status == 0, "\(packaged.stderr)")
        let listed = try String(contentsOf: out.appendingPathComponent("SHA256SUMS"), encoding: .utf8).split(separator: "\n").map { String($0.dropFirst(66)) }
        #expect(listed == ["offsider-0.0.0-arm64.tar.gz", "build-info.txt", "offsider-0.0.0.cdx.json", "SECURITY.md"])
    }

    /// A dist folder holding a made-up stage for version 0.0.0, with nothing in it worth signing.
    private static func stagedDirectory() throws -> URL {
        let dist = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-release-\(UUID().uuidString)")
        let stage = dist.appendingPathComponent("offsider-0.0.0-arm64")
        for folder in ["Offsider_Offsider.bundle", "Frameworks"] {
            try FileManager.default.createDirectory(at: stage.appendingPathComponent(folder), withIntermediateDirectories: true)
            try Data("x\n".utf8).write(to: stage.appendingPathComponent(folder).appendingPathComponent("file"))
        }
        for file in ["offsider", "LICENSE", "THIRD_PARTY_LICENSES"] {
            try Data("x\n".utf8).write(to: stage.appendingPathComponent(file))
        }
        return dist
    }

    @Test("package lists the tarball first, then the build record, the SBOM and SECURITY.md, each with its own digest")
    func packageListsEveryProofFile() throws {
        let dist = try Self.stagedDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        let proof = ["build-info.txt", "offsider-0.0.0.cdx.json", "SECURITY.md"]
        for name in proof { try Data("\(name)\n".utf8).write(to: dist.appendingPathComponent(name)) }
        let result = try Self.run(["package", "--version", "0.0.0", "--dist", dist.path])
        #expect(result.status == 0, "\(result.stderr)")

        let sums = try String(contentsOf: dist.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let expected = try (["offsider-0.0.0-arm64.tar.gz"] + proof).map { "\(try Self.sha256(dist.appendingPathComponent($0)))  \($0)" }
        #expect(sums.split(separator: "\n").map(String.init) == expected)
    }

    @Test("package refuses to write SHA256SUMS while a proof file is missing", arguments: ["build-info.txt", "offsider-0.0.0.cdx.json", "SECURITY.md"])
    func packageRefusesWithoutAProofFile(missing: String) throws {
        let dist = try Self.stagedDirectory()
        defer { try? FileManager.default.removeItem(at: dist) }
        for name in ["build-info.txt", "offsider-0.0.0.cdx.json", "SECURITY.md"] where name != missing {
            try Data("x\n".utf8).write(to: dist.appendingPathComponent(name))
        }
        let result = try Self.run(["package", "--version", "0.0.0", "--dist", dist.path])
        #expect(result.status == 1)
        #expect(result.stderr.contains("\(missing) (run record first)"))
        #expect(!FileManager.default.fileExists(atPath: dist.appendingPathComponent("SHA256SUMS").path))
        #expect(!FileManager.default.fileExists(atPath: dist.appendingPathComponent("offsider-0.0.0-arm64.tar.gz").path))
    }

    /// Git with no configuration but the repository's own, so a test never reaches a person's signing key.
    private static let isolatedGit = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

    @discardableResult
    private static func git(_ directory: URL, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(isolatedGit) { _, new in new }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let printed = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        return printed
    }

    /// A clone on `main` equal to its `origin`, holding release.sh and a SECURITY.md whose first line is `securityLine`, that signs with a throwaway key.
    private struct TagFixture {
        let base: URL
        var work: URL { base.appendingPathComponent("work") }
        var origin: URL { base.appendingPathComponent("origin.git") }
        var script: URL { work.appendingPathComponent("scripts/release.sh") }

        init(securityLine: String = "**As of version 1.2.3.**\n") throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-release-tag-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: ReleaseScriptTests.root.appendingPathComponent("scripts/release.sh"), to: script)
            try Data("\(securityLine)\n# Security policy\n".utf8).write(to: work.appendingPathComponent("SECURITY.md"))

            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "release-test", "-f", base.appendingPathComponent("key").path]
            keygen.standardOutput = Pipe()
            try keygen.run()
            keygen.waitUntilExit()
            try #require(keygen.terminationStatus == 0)

            try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
            try ReleaseScriptTests.git(origin, "init", "-q", "--bare", "-b", "main")
            try ReleaseScriptTests.git(work, "init", "-q", "-b", "main")
            for (key, value) in [
                "user.name": "Release Test", "user.email": "release-test@localhost", "commit.gpgsign": "false",
                "gpg.format": "ssh", "gpg.ssh.program": "/usr/bin/ssh-keygen", "user.signingkey": base.appendingPathComponent("key").path,
            ] {
                try ReleaseScriptTests.git(work, "config", key, value)
            }
            try ReleaseScriptTests.git(work, "add", ".")
            try ReleaseScriptTests.git(work, "commit", "-qm", "release 1.2.3")
            try ReleaseScriptTests.git(work, "remote", "add", "origin", origin.path)
            try ReleaseScriptTests.git(work, "push", "-q", "-u", "origin", "main")
        }

        func tag(_ version: String = "1.2.3") throws -> (status: Int32, stderr: String, stdout: String) {
            try ReleaseScriptTests.run(script: script, ["tag", "--version", version], setting: ReleaseScriptTests.isolatedGit)
        }

        func tags(in repository: URL) throws -> String {
            try ReleaseScriptTests.git(repository, "tag", "--list")
        }

        func commit(_ message: String, in repository: URL) throws {
            try Data("\(message)\n".utf8).write(to: repository.appendingPathComponent("NOTES"))
            try ReleaseScriptTests.git(repository, "add", "NOTES")
            try ReleaseScriptTests.git(repository, "commit", "-qm", message)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    @Test("tag makes a signed tag on main, prints the push command and pushes nothing")
    func tagSignsAndLeavesThePushToAPerson() throws {
        let fixture = try TagFixture()
        defer { fixture.remove() }
        let result = try fixture.tag()
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout == "git push origin v1.2.3\n")
        #expect(result.stderr.contains("nothing was pushed"))

        #expect(try Self.git(fixture.work, "cat-file", "-t", "refs/tags/v1.2.3") == "tag\n")
        #expect(try Self.git(fixture.work, "rev-parse", "v1.2.3^{commit}") == Self.git(fixture.work, "rev-parse", "HEAD"))
        #expect(try Self.git(fixture.work, "tag", "--list", "--format=%(contents:subject)", "v1.2.3") == "Offsider 1.2.3\n")
        let publicKey = try String(contentsOf: fixture.base.appendingPathComponent("key.pub"), encoding: .utf8)
        let signers = fixture.base.appendingPathComponent("allowed_signers")
        try Data("release-test@localhost namespaces=\"git\" \(publicKey)".utf8).write(to: signers)
        try Self.git(fixture.work, "-c", "gpg.ssh.allowedSignersFile=\(signers.path)", "verify-tag", "v1.2.3")
        #expect(try fixture.tags(in: fixture.origin).isEmpty)
    }

    @Test("tag refuses while line 1 of SECURITY.md names another version, and makes no tag")
    func tagRefusesAStaleSecurityLine() throws {
        let fixture = try TagFixture(securityLine: "**As of version 1.2.2.**\n")
        defer { fixture.remove() }
        let result = try fixture.tag()
        #expect(result.status == 1)
        #expect(result.stderr.contains("line 1 of SECURITY.md must read '**As of version 1.2.3.**' (it reads '**As of version 1.2.2.**')"))
        #expect(result.stdout.isEmpty)
        #expect(try fixture.tags(in: fixture.work).isEmpty)
    }

    @Test("check-security lets trailing spaces and a CR through on line 1", arguments: ["**As of version 1.2.3.**\n", "**As of version 1.2.3.**   \n", "**As of version 1.2.3.**\r\n", "**As of version 1.2.3.**  \r\n"])
    func checkSecurityAcceptsTheVersionLine(line: String) throws {
        let fixture = try TagFixture(securityLine: line)
        defer { fixture.remove() }
        let result = try Self.run(script: fixture.script, ["check-security", "--version", "1.2.3"])
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test("check-security refuses anything else on line 1", arguments: [
        "# Security policy\n\n**As of version 1.2.3.**\n", "\n**As of version 1.2.3.**\n", " **As of version 1.2.3.**\n", "**As of version 1.2.3.**\t\n",
        "**As of version 1.2.3.** See below.\n", "**As of version 1.2.3**\n", "As of version 1.2.3.\n", "**As of version 1.2.30.**\n", "**As of version v1.2.3.**\n",
    ])
    func checkSecurityRefusesAnotherLine(line: String) throws {
        let fixture = try TagFixture(securityLine: line)
        defer { fixture.remove() }
        let result = try Self.run(script: fixture.script, ["check-security", "--version", "1.2.3"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("line 1 of SECURITY.md must read '**As of version 1.2.3.**'"))
    }

    @Test("tag refuses a working tree with a changed or an untracked file", arguments: ["SECURITY.md", "untracked.txt"])
    func tagRefusesADirtyTree(file: String) throws {
        let fixture = try TagFixture()
        defer { fixture.remove() }
        try Data("**As of version 1.2.3.**\nchanged\n".utf8).write(to: fixture.work.appendingPathComponent(file))
        let result = try fixture.tag()
        #expect(result.status == 1)
        #expect(result.stderr.contains("the working tree has changes"))
        #expect(try fixture.tags(in: fixture.work).isEmpty)
    }

    @Test("tag refuses a main with a commit origin lacks")
    func tagRefusesMainAheadOfOrigin() throws {
        let fixture = try TagFixture()
        defer { fixture.remove() }
        try fixture.commit("not pushed", in: fixture.work)
        let result = try fixture.tag()
        #expect(result.status == 1)
        #expect(result.stderr.contains("main is not origin/main"))
        #expect(try fixture.tags(in: fixture.work).isEmpty)
    }

    @Test("tag fetches first, so it refuses a main that origin has moved past")
    func tagRefusesMainBehindOrigin() throws {
        let fixture = try TagFixture()
        defer { fixture.remove() }
        let other = fixture.base.appendingPathComponent("other")
        try Self.git(fixture.base, "clone", "-q", fixture.origin.path, other.path)
        try Self.git(other, "config", "user.name", "Release Test")
        try Self.git(other, "config", "user.email", "release-test@localhost")
        try fixture.commit("merged after the last fetch", in: other)
        try Self.git(other, "push", "-q", "origin", "main")
        let result = try fixture.tag()
        #expect(result.status == 1)
        #expect(result.stderr.contains("main is not origin/main"))
        #expect(try fixture.tags(in: fixture.work).isEmpty)
    }

    @Test("tag refuses a branch other than main")
    func tagRefusesAnotherBranch() throws {
        let fixture = try TagFixture()
        defer { fixture.remove() }
        try Self.git(fixture.work, "switch", "-q", "-c", "release/1.2.3")
        let result = try fixture.tag()
        #expect(result.status == 1)
        #expect(result.stderr.contains("check out main first"))
        #expect(try fixture.tags(in: fixture.work).isEmpty)
    }

    @Test("tag refuses a tag that already exists here")
    func tagRefusesAnExistingLocalTag() throws {
        let fixture = try TagFixture()
        defer { fixture.remove() }
        try Self.git(fixture.work, "tag", "v1.2.3")
        let result = try fixture.tag()
        #expect(result.status == 1)
        #expect(result.stderr.contains("tag v1.2.3 already exists here"))
        #expect(try Self.git(fixture.work, "cat-file", "-t", "refs/tags/v1.2.3") == "commit\n")
    }

    @Test("tag refuses a tag that exists only on origin")
    func tagRefusesAnExistingRemoteTag() throws {
        let fixture = try TagFixture()
        defer { fixture.remove() }
        try Self.git(fixture.origin, "tag", "v1.2.3", "main")
        let result = try fixture.tag()
        #expect(result.status == 1)
        #expect(result.stderr.contains("tag v1.2.3 already exists on origin"))
        #expect(try fixture.tags(in: fixture.work).isEmpty)
    }
}
