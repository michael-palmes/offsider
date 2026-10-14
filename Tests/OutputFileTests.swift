import Darwin
import Foundation
import OffsiderCore
import Testing

@Suite("Output files")
struct OutputFileTests {
    static func folder() throws -> String {
        let path = NSTemporaryDirectory() + "offsider-output-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    @Test("a device name becomes one safe file name component", arguments: [
        ("iPhone 17 Pro", "iPhone 17 Pro"),
        ("../../etc/passwd", "-..-etc-passwd"),
        ("a/b:c", "a-b-c"),
        ("tab\there\u{7F}\u{85}", "tab-here--"),
        ("\u{202E}gnp.exe\u{200B}", "gnp.exe"),
        ("...hidden", "hidden"),
        ("", "device"),
        ("\u{200D}\u{2066}", "device"),
        (String(repeating: "x", count: 100), String(repeating: "x", count: 64)),
    ])
    func sanitised(input: String, expected: String) {
        #expect(OutputFile.sanitisedComponent(input) == expected)
    }

    @Test("a new file is created 0600 and never over an existing one: the next free name takes \" 2\", \" 3\"")
    func writeNewSuffixes() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let target = folder + "/Shot.png"
        #expect(try OutputFile.writeNew(Data("one".utf8), at: target) == target)
        #expect(try OutputFile.writeNew(Data("two".utf8), at: target) == folder + "/Shot 2.png")
        #expect(try OutputFile.writeNew(Data("three".utf8), at: target) == folder + "/Shot 3.png")
        #expect(FileManager.default.contents(atPath: target) == Data("one".utf8))
        #expect(Self.mode(target) == 0o600)
    }

    @Test("a generated name never writes through a symbolic link planted there")
    func writeNewSkipsLink() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let victim = folder + "/victim.txt"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: victim))
        try FileManager.default.createSymbolicLink(atPath: folder + "/Shot.png", withDestinationPath: victim)
        #expect(try OutputFile.writeNew(Data("img".utf8), at: folder + "/Shot.png") == folder + "/Shot 2.png")
        #expect(FileManager.default.contents(atPath: victim) == Data("keep".utf8))
    }

    @Test("a named file is replaced whole when it is this user's image or video")
    func replacesOwnImage() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let target = folder + "/out.PNG"
        try Data("old".utf8).write(to: URL(fileURLWithPath: target))
        try OutputFile.replace(Data("new".utf8), at: target)
        #expect(FileManager.default.contents(atPath: target) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["out.PNG"])
        try OutputFile.replace(Data("fresh".utf8), at: folder + "/new.png")
        #expect(FileManager.default.contents(atPath: folder + "/new.png") == Data("fresh".utf8))
    }

    @Test("a named path that is a link, a directory, another kind of file or someone else's is refused and left alone")
    func replaceRefusals() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let notes = folder + "/notes.txt"
        try Data("mine".utf8).write(to: URL(fileURLWithPath: notes))
        let link = folder + "/link.png"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: notes)
        try FileManager.default.createDirectory(atPath: folder + "/dir.png", withIntermediateDirectories: false)
        mkfifo(folder + "/pipe.png", 0o600)
        let own = folder + "/own.png"
        try Data("x".utf8).write(to: URL(fileURLWithPath: own))

        for path in [notes, link, folder + "/dir.png", folder + "/pipe.png"] {
            #expect(throws: OutputFileError.self) { try OutputFile.replace(Data("evil".utf8), at: path) }
        }
        #expect(throws: OutputFileError.self) { try OutputFile.replace(Data("evil".utf8), at: own, uid: getuid() + 1) }
        #expect(FileManager.default.contents(atPath: notes) == Data("mine".utf8))
        #expect(FileManager.default.contents(atPath: own) == Data("x".utf8))
    }

    @Test("a staged recording moves to a free name, or replaces a named file, and the staging folder goes")
    func stagingCommit() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let target = folder + "/video.mp4"
        try Data("taken".utf8).write(to: URL(fileURLWithPath: target))

        let staging = try OutputFile.stagingDirectory(for: target)
        #expect(Self.mode(staging) == 0o700)
        try Data("movie".utf8).write(to: URL(fileURLWithPath: staging + "/recording.mp4"))
        #expect(try OutputFile.commit(staging + "/recording.mp4", to: target, replacing: false) == folder + "/video 2.mp4")
        #expect(Self.mode(folder + "/video 2.mp4") == 0o600)
        #expect(!FileManager.default.fileExists(atPath: staging))

        let again = try OutputFile.stagingDirectory(for: target)
        try Data("second".utf8).write(to: URL(fileURLWithPath: again + "/recording.mp4"))
        #expect(try OutputFile.commit(again + "/recording.mp4", to: target, replacing: true) == target)
        #expect(FileManager.default.contents(atPath: target) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["video 2.mp4", "video.mp4"])
    }
}
