import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Text from --file")
struct TextFileInputTests {
    /// A fresh folder standing in for both the working directory and the home directory.
    static func folder() throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-file-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return TextFileInputTests.real(path)
    }

    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func refusal(_ body: () throws -> TextFileInput.Text) -> TextFileInput.Refused? {
        do {
            _ = try body()
            Issue.record("expected the file to be refused")
            return nil
        } catch let refused as TextFileInput.Refused {
            return refused
        } catch {
            Issue.record("expected TextFileInput.Refused, got \(error)")
            return nil
        }
    }

    @Test("a relative path resolves against the working directory and reports the resolved path and size")
    func readsRelative() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.write("héllo\n", to: root + "/notes/text.txt")

        let read = try TextFileInput.read("notes/../notes/text.txt", allowSensitive: false, home: "/nonexistent-home", cwd: root)
        #expect(read.text == "héllo\n")
        #expect(read.resolvedPath == root + "/notes/text.txt")
        #expect(read.announcement == "Reading text from \(root)/notes/text.txt (7 bytes)")
        #expect(read.byteCount == 7)
    }

    @Test("a FIFO is refused at once, never waited on")
    func fifo() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/pipe"
        #expect(mkfifo(path, 0o600) == 0)

        let started = Date()
        let refused = Self.refusal { try TextFileInput.read(path, allowSensitive: false, home: "/nonexistent-home") }
        #expect(refused?.message == "\(path) is not a regular file, so --file will not read it.")
        #expect(refused?.reason == .inputFileRefused)
        #expect(refused?.reason.exitCode.rawValue == 64)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("a directory is refused")
    func directory() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let refused = Self.refusal { try TextFileInput.read(root, allowSensitive: false, home: "/nonexistent-home") }
        #expect(refused?.message.contains("is not a regular file") == true)
    }

    @Test("64 KiB is read, and one byte more is refused")
    func sizeLimit() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.write(String(repeating: "a", count: 65_536), to: root + "/full.txt")
        try Self.write(String(repeating: "a", count: 65_537), to: root + "/over.txt")

        #expect(try TextFileInput.read(root + "/full.txt", allowSensitive: false, home: "/nonexistent-home").byteCount == 65_536)
        let refused = Self.refusal { try TextFileInput.read(root + "/over.txt", allowSensitive: false, home: "/nonexistent-home") }
        #expect(refused?.message == "\(root)/over.txt is larger than 64 KiB, the most --file reads.")
    }

    @Test("text that is not UTF-8 is refused")
    func notUTF8() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data([0xFF, 0xFE, 0x41]).write(to: URL(fileURLWithPath: root + "/latin.txt"))
        let refused = Self.refusal { try TextFileInput.read(root + "/latin.txt", allowSensitive: false, home: "/nonexistent-home") }
        #expect(refused?.message.contains("is not UTF-8 text") == true)
    }

    @Test("a symlink into ~/.ssh is judged by where it leads, and --allow-path reads it")
    func symlinkIntoSSH() throws {
        let home = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.write("ssh-ed25519 AAAA", to: home + "/.ssh/x")
        try FileManager.default.createSymbolicLink(atPath: home + "/innocent.txt", withDestinationPath: home + "/.ssh/x")

        let refused = Self.refusal { try TextFileInput.read(home + "/innocent.txt", allowSensitive: false, home: home) }
        #expect(refused?.message == "Offsider will not read \(home)/.ssh/x with --file: it is under ~/.ssh, which holds keys and tokens. Add --allow-path if you meant that file.")
        let allowed = try TextFileInput.read(home + "/innocent.txt", allowSensitive: true, home: home)
        #expect(allowed.resolvedPath == home + "/.ssh/x")
    }

    @Test("names that usually hold secrets are refused, and .env.example is not", arguments: [
        (".env", true), (".env.local", true), (".ENV.production", true), (".netrc", true), (".git-credentials", true), (".npmrc", true),
        (".pypirc", true), ("id_ed25519", true), ("cert.pem", true), ("bundle.p12", true), ("server.key", true),
        (".zsh_history", true), (".bash_history", true), (".zhistory", true), (".python_history", true), (".node_repl_history", true),
        ("release.jks", true), ("debug.keystore", true), ("credentials.json", true), ("credentials-prod.json", true), ("terraform.tfstate", true),
        (".env.example", false), ("notes.txt", false), ("keys.txt", false), ("credentials.md", false), ("history.txt", false),
    ])
    func sensitiveNames(name: String, refused: Bool) throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.write("x", to: root + "/" + name)
        let result = Result { try TextFileInput.read(root + "/" + name, allowSensitive: false, home: "/nonexistent-home") }
        if refused {
            #expect((try? result.get()) == nil)
            #expect(try TextFileInput.read(root + "/" + name, allowSensitive: true, home: "/nonexistent-home").text == "x")
        } else {
            #expect(try result.get().text == "x")
        }
    }

    @Test("folders that hold keys and system configuration are refused", arguments: [
        ".aws/credentials", ".config/gh/hosts.yml", ".gnupg/pubring.kbx", ".docker/config.json", ".kube/config",
        "Library/Keychains/login.keychain-db", "Library/Application Support/offsider/state.json", ".android/adbkey", ".android/adbkey.pub",
    ])
    func sensitiveFolders(path: String) throws {
        let home = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.write("x", to: home + "/" + path)
        let refused = Self.refusal { try TextFileInput.read(home + "/" + path, allowSensitive: false, home: home) }
        #expect(refused?.message.contains("Add --allow-path if you meant that file.") == true)
    }

    @Test("/etc is refused through its /private/etc target")
    func systemFolder() {
        let refused = Self.refusal { try TextFileInput.read("/etc/hosts", allowSensitive: false, home: "/nonexistent-home") }
        #expect(refused?.message.contains("it is under /private/etc, which holds system configuration") == true)
    }

    @Test("a missing file is refused naming the path as given")
    func missing() {
        let refused = Self.refusal { try TextFileInput.read("/nonexistent-offsider/text.txt", allowSensitive: false, home: "/nonexistent-home") }
        #expect(refused?.message.hasPrefix("Could not open /nonexistent-offsider/text.txt for --file") == true)
    }

    @Test("a confirmed path reads only while the name still resolves to it, and other files under ~/.android are not keys")
    func confirmedPath() throws {
        let home = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.write("key", to: home + "/.android/adbkey")
        try Self.write("ok", to: home + "/.android/avd/notes.txt")
        try Self.write("other", to: home + "/.ssh/other")
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: home + "/.android/adbkey")

        let found = try #require(TextFileInput.sensitive(home + "/link", home: home))
        #expect(found.resolvedPath == home + "/.android/adbkey")
        #expect(try TextFileInput.read(home + "/link", allowing: found.resolvedPath, home: home).text == "key")
        #expect(Self.refusal { try TextFileInput.read(home + "/link", allowing: nil, home: home) } != nil)

        try FileManager.default.removeItem(atPath: home + "/link")
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: home + "/.ssh/other")
        #expect(Self.refusal { try TextFileInput.read(home + "/link", allowing: found.resolvedPath, home: home) } != nil)

        #expect(TextFileInput.sensitive(home + "/.android/avd/notes.txt", home: home) == nil)
        #expect(try TextFileInput.read(home + "/.android/avd/notes.txt", allowing: nil, home: home).text == "ok")
    }
}
