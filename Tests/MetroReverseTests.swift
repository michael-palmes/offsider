import Darwin
import Foundation
import Testing
@testable import OffsiderCore

@Suite("Metro reverse rules and record")
struct MetroReverseTests {
    @Test("Metro ports are 1024 to 65535, never adb's server or an emulator's console, adb or gRPC port", arguments: [
        (8081, true), (8742, true), (1024, true), (65_535, true), (19_000, true),
        (1023, false), (22, false), (0, false), (65_536, false), (5037, false), (5554, false), (5555, false), (5682, false), (8554, false), (8682, false),
    ])
    func portRange(port: Int, allowed: Bool) {
        #expect((MetroReverse.refusal(port: port) == nil) == allowed)
    }

    @Test("a reverse counts as Offsider's shape only when both sides name the same port; any phone-side match routes the dev client")
    func listingShapes() {
        let listing = "host-27 tcp:8081 tcp:8081\nhost-27 tcp:8742 tcp:9000\n"
        #expect(MetroReverse.mapsSamePort(listing, port: 8081))
        #expect(!MetroReverse.mapsSamePort(listing, port: 8742))
        #expect(MetroReverse.phoneListens(listing, port: 8742))
        #expect(!MetroReverse.phoneListens(listing, port: 9000))
        #expect(ExpoDevClient.androidMetroHost(reverseList: listing, port: 8742, isEmulator: false) == ExpoDevClient.loopback)
        #expect(ExpoDevClient.androidMetroHost(reverseList: listing, port: 9000, isEmulator: false) == nil)
    }

    @Test("a record whose file name does not match its serial, or holds a port Metro never uses, is ignored")
    func tamperedRecords() throws {
        let directory = NSTemporaryDirectory() + "offsider-reverse-record-\(UUID().uuidString)"
        try OffsiderPrivateDirectory.ensurePrivateDirectory(directory, uid: getuid())
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = MetroReverseStore(directory: directory)
        try store.save(MetroReverseRecord(serial: "R58M123ABC", transportId: "2", ports: [8081]))
        let moved = MetroReverseRecord(serial: "OTHER", transportId: "2", ports: [8081]).encoded()
        try OffsiderPrivateDirectory.writeAtomically(moved, named: MetroReverseRecord.fileName(serial: "R58M123ABC") + "x.json", in: directory)
        let adb = #"{"ports":[5037],"serial":"R58M123ABC","transportId":"2","version":1}"#
        #expect(MetroReverseRecord(data: Data(adb.utf8)) == nil)

        #expect(store.all().map(\.serial) == ["R58M123ABC"])
        try store.save(MetroReverseRecord(serial: "R58M123ABC", transportId: "2", ports: []))
        #expect(store.load(serial: "R58M123ABC") == nil)
    }

    @Test("doctor marks the reverses Offsider set, by both sides, and still passes")
    func doctorMarksOwnReverses() {
        let verdict = AndroidDoctorRules.metroReverse(["host-27 tcp:8081 tcp:8081", "host-27 tcp:8742 tcp:9000"], offsider: [8081, 8742])
        #expect(verdict.status == .pass)
        #expect(verdict.detail == "tcp:8081 to tcp:8081 (set by Offsider until session stop), tcp:8742 to tcp:9000 (Metro)")
    }
}

@Suite("Loopback owner")
struct LoopbackOwnerTests {
    /// A listener on 127.0.0.1 in this process; with `accepting` a thread accepts and holds each connection until the test ends.
    final class Listener: @unchecked Sendable {
        let descriptor: Int32
        let port: Int
        private let lock = NSLock()
        private var accepted: [Int32] = []

        /// `dualStack` binds `::` with IPv4 allowed, as Node does by default; otherwise 127.0.0.1.
        init(accepting: Bool, dualStack: Bool = false) throws {
            let socket = CloseOnExecSocket.make(dualStack ? AF_INET6 : AF_INET, SOCK_STREAM)
            let bound: Int32
            if dualStack {
                var off: Int32 = 0
                setsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            } else {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
                bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
            guard bound == 0, listen(socket, 4) == 0 else {
                close(socket)
                throw POSIXError(.EADDRINUSE)
            }
            var name = sockaddr_in6()
            var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &name) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) } }
            descriptor = socket
            port = Int(UInt16(bigEndian: name.sin6_port))
            guard accepting else { return }
            Thread.detachNewThread { [self] in
                while true {
                    let connection = CloseOnExecSocket.accept(descriptor)
                    guard connection >= 0 else { return }
                    lock.withLock { accepted.append(connection) }
                }
            }
        }

        deinit {
            close(descriptor)
            lock.withLock { accepted.forEach { close($0) } }
        }
    }

    @Test("a port whose listener runs as this user and accepts the connection is this user's, on 127.0.0.1 or dual-stack ::", arguments: [false, true])
    func ownListener(dualStack: Bool) throws {
        let listener = try Listener(accepting: true, dualStack: dualStack)
        #expect(LoopbackOwner.acceptedByUser(port: listener.port))
    }

    @Test("another user's listener, one that never accepts, or none at all is not", arguments: ["other user", "never accepts", "nothing"])
    func notOwned(case name: String) throws {
        let listener = try Listener(accepting: name != "never accepts")
        let port = name == "nothing" ? Self.closedPort() : listener.port
        let uid = name == "other user" ? getuid() + 4_000 : getuid()
        #expect(!LoopbackOwner.acceptedByUser(port: port, uid: uid, wait: .milliseconds(200)))
    }

    /// A port nothing listens on: bound, read and closed again.
    static func closedPort() -> Int {
        let probe = try? Listener(accepting: false)
        return probe?.port ?? 1
    }
}
