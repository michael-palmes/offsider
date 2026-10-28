import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("devicectl app and process replies")
struct DevicectlAppProcessTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let udid = "00008130-0000000000000ABC"
    static let bundleURL = "file:///private/var/containers/Bundle/Application/00000000-0000-4000-8000-000000000001/OffsiderPlayground.app/"

    @Test("the app's row gives its name, version, build and a developer install, and its bundle's location")
    func appRow() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("devicectl-info-apps.json"))
        let app = try #require(try DevicectlAppProcess.app(data, bundleID: "com.mpalmes.offsider.playground"))
        #expect(app.info == AppInfo(app: "com.mpalmes.offsider.playground", name: "Offsider Playground", version: "1.0", build: "1", installer: "developer"))
        #expect(app.bundleURL == Self.bundleURL)
        let store = try #require(try DevicectlAppProcess.app(data, bundleID: "com.example.notes"))
        #expect(store.info.installer == nil && store.info.version == nil)
        #expect(try DevicectlAppProcess.app(data, bundleID: "com.example.absent") == nil)
    }

    @Test("a failed or malformed reply is an error, not an empty answer")
    func badReplies() {
        #expect(throws: DevicectlDeviceList.ParseError.self) { try DevicectlAppProcess.app(Data(#"{"info":{"outcome":"failed"},"result":{}}"#.utf8), bundleID: "a.b") }
        #expect(throws: DevicectlDeviceList.ParseError.self) { try DevicectlAppProcess.app(Data("not json".utf8), bundleID: "a.b") }
        #expect(throws: DevicectlDeviceList.ParseError.self) { try DevicectlAppProcess.pid(Data(#"{"info":{"outcome":"success"},"result":{}}"#.utf8), bundleURL: Self.bundleURL) }
    }

    @Test("the app's process is the one whose executable sits inside its bundle, not one that merely shares a prefix")
    func processByBundle() throws {
        let reply = """
        {"info":{"outcome":"success"},"result":{"runningProcesses":[
          {"executable":"file:///usr/libexec/backboardd","processIdentifier":61},
          {"executable":"file:///private/var/containers/Bundle/Application/00000000-0000-4000-8000-000000000001/OffsiderPlayground.app.evil/x","processIdentifier":90},
          {"executable":"file:///private/var/containers/Bundle/Application/00000000-0000-4000-8000-000000000001/OffsiderPlayground.app/OffsiderPlayground","processIdentifier":4021}
        ]}}
        """
        #expect(try DevicectlAppProcess.pid(Data(reply.utf8), bundleURL: Self.bundleURL) == 4021)
        #expect(try DevicectlAppProcess.pid(Data(reply.utf8), bundleURL: String(Self.bundleURL.dropLast())) == 4021)
        let none = #"{"info":{"outcome":"success"},"result":{"runningProcesses":[{"executable":"file:///usr/libexec/backboardd","processIdentifier":61}]}}"#
        #expect(try DevicectlAppProcess.pid(Data(none.utf8), bundleURL: Self.bundleURL) == nil)
    }

    @Test("a launch reply gives the new process")
    func launchReply() {
        let reply = #"{"info":{"outcome":"success"},"result":{"process":{"executableURL":{"relative":"file:///x"},"processIdentifier":4022}}}"#
        #expect(DevicectlAppProcess.launchedPID(Data(reply.utf8)) == 4022)
        #expect(DevicectlAppProcess.launchedPID(Data("{}".utf8)) == nil)
    }

    @Test("info narrows to one bundle ID and includes store and TestFlight apps; a link goes to the named app as a payload")
    func arguments() {
        let info = DevicectlAppProcess.infoArguments(udid: Self.udid, bundleID: "com.example.app")
        #expect(info.contains("--include-default-apps"))
        #expect(info.firstIndex(of: "--bundle-id").map { info[$0 + 1] } == "com.example.app")
        #expect(!info.contains("--include-all-apps"))
        let open = DevicectlAppProcess.launchArguments(udid: Self.udid, bundleID: "com.example.app", restart: true, url: "https://example.com/a?b=1&c=2")
        #expect(open.firstIndex(of: "--payload-url").map { open[$0 + 1] } == "https://example.com/a?b=1&c=2")
        #expect(open.contains("--terminate-existing"))
        #expect(open.last == "com.example.app")
        #expect(DevicectlAppProcess.terminateArguments(udid: Self.udid, pid: 4021).contains("4021"))
    }
}
