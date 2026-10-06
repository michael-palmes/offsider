import Foundation
@testable import OffsiderIOSDevice
import Testing

@Suite("iOS device runner log watch")
struct RunnerLogWatchTests {
    static func fixturePrompt() throws -> String {
        let fixture = try IOSDeviceFixtures.text("xcodebuild-runner-locked.log")
        return String(try #require(fixture.split(separator: "\n").first { $0.hasPrefix("Error Domain=") }))
    }

    static func temporaryLog() throws -> String {
        let directory = RunnerTestPaths.temporaryRoot()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return (directory as NSString).appendingPathComponent("runner.log")
    }

    static func append(_ text: String, to path: String) throws {
        try append(Data(text.utf8), to: path)
    }

    static func append(_ data: Data, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    @Test("xcodebuild's device-preparation unlock prompt is found whatever the device is called, and the name alone never matches", arguments: [
        ("fixture", true),
        (#"Error Domain=com.apple.dt.deviceprep Code=-3 "Unlock Sam's iPhone to Continue" UserInfo={}"#, true),
        (#"2026-10-07 09:12:33.123 xcodebuild[812:9001] Error Domain=com.apple.dt.deviceprep Code=-3 "unlock “Lab iPad” to continue""#, true),
        ("Testing on Unlocked iPad (2)", false),
        ("** BUILD INTERRUPTED **", false),
    ])
    func prompt(line: String, locked: Bool) throws {
        let text = line == "fixture" ? try Self.fixturePrompt() : line
        #expect(RunnerLogWatch.finding(in: text) == (locked ? .deviceLocked : nil))
    }

    @Test("each check reads only what was appended since the last, so a prompt split across two writes is found once")
    func appendedOnly() throws {
        let path = try Self.temporaryLog()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        var watch = RunnerLogWatch(path: path)
        #expect(watch.check() == nil)

        let header = "Command line invocation:\n    xcodebuild test-without-building\n\n"
        try Self.append(header, to: path)
        #expect(watch.check() == nil)
        #expect(watch.offset == off_t(header.utf8.count))

        let prompt = Data(try Self.fixturePrompt().utf8) + Data("\n".utf8)
        let split = try #require(prompt.range(of: Data("devi".utf8))).upperBound
        try Self.append(prompt[..<split], to: path)
        #expect(watch.check() == nil)
        try Self.append(prompt[split...], to: path)
        #expect(watch.check() == .deviceLocked)
        #expect(watch.check() == nil)
    }

    @Test("a check reads at most one chunk, so a burst of output is read over several checks")
    func bounded() throws {
        let path = try Self.temporaryLog()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let noise = String(repeating: "Test Case passed.\n", count: RunnerLogWatch.chunkLimit / 18 + 10)
        try Self.append(noise + (try Self.fixturePrompt()) + "\n", to: path)
        var watch = RunnerLogWatch(path: path)

        #expect(watch.check() == nil)
        #expect(watch.offset == off_t(RunnerLogWatch.chunkLimit))
        #expect(watch.check() == .deviceLocked)
    }

    @Test("a log that is missing or a symbolic link reads as nothing")
    func missingOrLinked() throws {
        let path = try Self.temporaryLog()
        let directory = (path as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var watch = RunnerLogWatch(path: path)
        #expect(watch.check() == nil)

        let target = (directory as NSString).appendingPathComponent("elsewhere.log")
        try Self.append(try Self.fixturePrompt() + "\n", to: target)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        #expect(watch.check() == nil)
        #expect(watch.offset == 0)
    }
}
