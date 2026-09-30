import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Loopback endpoint")
struct LoopbackEndpointTests {
    @Test("ADB_SERVER_SOCKET accepts loopback literals and Unix paths", arguments: [
        ("tcp:5037", LoopbackEndpoint.tcp(.ipv4, port: 5037)),
        ("tcp:127.0.0.1:5038", .tcp(.ipv4, port: 5038)),
        ("tcp:[::1]:5037", .tcp(.ipv6, port: 5037)),
        ("tcp:::1:5037", .tcp(.ipv6, port: 5037)),
        ("tcp:localhost:5037", .tcp(.ipv4, port: 5037)),
        ("localfilesystem:/tmp/x", .unix(path: "/tmp/x")),
    ])
    func acceptsLoopback(spec: String, expected: LoopbackEndpoint) throws {
        #expect(try LoopbackEndpoint.parse(adbSocketSpec: spec) == expected)
    }

    @Test("anything that could leave the Mac is refused, naming the variable", arguments: [
        "tcp:192.168.1.5:5037", "tcp:example.com:5037", "tcp:0.0.0.0:5037", "tcp:127.0.0.2:5037", "localabstract:adb",
    ])
    func refusesNonLoopback(spec: String) {
        let error = #expect(throws: AndroidError.self) {
            try LoopbackEndpoint.adbServer(environment: ["ADB_SERVER_SOCKET": spec])
        }
        #expect(error?.kind == .nonLoopbackAdbServer)
        #expect(error?.message.hasPrefix("ADB_SERVER_SOCKET is \(spec), which is not on this Mac.") == true)
    }

    @Test("ports outside 1 to 65535 and malformed specs are refused", arguments: [
        "tcp:65536", "tcp:0", "tcp:127.0.0.1:", "tcp:abc", "localfilesystem:relative",
    ])
    func refusesMalformed(spec: String) {
        let error = #expect(throws: AndroidError.self) {
            try LoopbackEndpoint.parse(adbSocketSpec: spec)
        }
        #expect(error?.kind == .invalidAdbServerSetting)
        #expect(error?.message.contains("ADB_SERVER_SOCKET is \(spec)") == true)
    }

    @Test("ADB_SERVER_SOCKET wins over the address and port variables")
    func socketVariableWins() throws {
        let endpoint = try LoopbackEndpoint.adbServer(environment: [
            "ADB_SERVER_SOCKET": "tcp:6000",
            "ANDROID_ADB_SERVER_ADDRESS": "192.168.1.5",
            "ANDROID_ADB_SERVER_PORT": "7000",
        ])
        #expect(endpoint == .tcp(.ipv4, port: 6000))
    }

    @Test("address and port variables combine, and the default is 127.0.0.1:5037")
    func addressAndPort() throws {
        #expect(try LoopbackEndpoint.adbServer(environment: [:]) == .defaultAdbServer)
        #expect(try LoopbackEndpoint.adbServer(environment: ["ANDROID_ADB_SERVER_PORT": "5099"]) == .tcp(.ipv4, port: 5099))
        #expect(
            try LoopbackEndpoint.adbServer(environment: ["ANDROID_ADB_SERVER_ADDRESS": "::1", "ANDROID_ADB_SERVER_PORT": "5099"])
                == .tcp(.ipv6, port: 5099)
        )
    }

    @Test("a remote ANDROID_ADB_SERVER_ADDRESS is refused by name")
    func remoteAddressRefused() {
        let error = #expect(throws: AndroidError.self) {
            try LoopbackEndpoint.adbServer(environment: ["ANDROID_ADB_SERVER_ADDRESS": "adb.example.com"])
        }
        #expect(error?.message.hasPrefix("ANDROID_ADB_SERVER_ADDRESS is adb.example.com") == true)
    }

    @Test("a bad ANDROID_ADB_SERVER_PORT names the variable and the valid range")
    func badPortVariable() {
        let error = #expect(throws: AndroidError.self) {
            try LoopbackEndpoint.adbServer(environment: ["ANDROID_ADB_SERVER_PORT": "99999"])
        }
        #expect(error?.message == "ANDROID_ADB_SERVER_PORT is 99999, which Offsider cannot read. Use a port from 1 to 65535, or unset it.")
    }

    @Test("descriptions are the address users would type")
    func descriptions() {
        #expect(LoopbackEndpoint.defaultAdbServer.description == "127.0.0.1:5037")
        #expect(LoopbackEndpoint.tcp(.ipv6, port: 5037).description == "[::1]:5037")
    }
}
