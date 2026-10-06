import Foundation
@testable import OffsiderIOSDevice
import Testing

@Suite("iOS device screen stream messages")
struct IOSDeviceScreenStreamTests {
    /// A captured `CoreDevice.output` plist as the XPC tree it came from; a string under `uuid` is an XPC UUID.
    static func value(_ plist: Any, key: String? = nil) -> MediaStreamValue {
        switch plist {
        case let dictionary as [String: Any]:
            return .dictionary(dictionary.reduce(into: [:]) { result, entry in result[entry.key] = value(entry.value, key: entry.key) })
        case let array as [Any]:
            return .array(array.map { value($0) })
        case let data as Data:
            return .data(data)
        case let text as String:
            return key == "uuid" ? .uuid(UUID(uuidString: text)!) : .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return number.int64Value < 0 ? .int(number.int64Value) : .uint(number.uint64Value)
        default:
            Issue.record("unexpected plist value \(plist)")
            return .string("")
        }
    }

    static func fixture(_ name: String) throws -> MediaStreamValue {
        value(try PropertyListSerialization.propertyList(from: try IOSDeviceFixtures.data(name), format: nil))
    }

    @Test("an iPad's start answer gives the session identifier, size and answer bytes")
    func startAnswer() throws {
        let answer = try MediaStreamAnswer.parse(try Self.fixture("mediastreamstart-output.plist"))
        #expect(answer.identifier == 2_600_940_412)
        #expect(answer.width == 2736)
        #expect(answer.height == 2064)
        #expect(answer.frameRate == 60)
        #expect(answer.session == UUID(uuidString: "00000000-0000-4000-8000-0000000000B1"))
        #expect(answer.negotiatorAnswer == Data("bplist00-scrubbed-answer".utf8))
        #expect(answer.senderPort != nil)
    }

    @Test("a start answer without the negotiator answer or session identifier is refused")
    func startAnswerIncomplete() throws {
        guard case .dictionary(var output) = try Self.fixture("mediastreamstart-output.plist") else { throw CancellationError() }
        let complete = output
        output["negotiatorAnswer"] = nil
        #expect(throws: MediaStreamAnswer.ParseError(detail: "no negotiator answer")) { try MediaStreamAnswer.parse(.dictionary(output)) }

        guard case .dictionary(var connection)? = complete["connection"], case .dictionary(var config)? = connection["streamConfig"] else { throw CancellationError() }
        config["RemoteSSRC"] = nil
        connection["streamConfig"] = .dictionary(config)
        var missingIdentifier = complete
        missingIdentifier["connection"] = .dictionary(connection)
        #expect(throws: MediaStreamAnswer.ParseError(detail: "no session identifier")) { try MediaStreamAnswer.parse(.dictionary(missingIdentifier)) }
    }

    @Test("the stop answer lists the sessions the device still runs")
    func serverStatus() throws {
        let status = MediaStreamServerStatus.parse(try Self.fixture("mediastreamstop-output.plist"))
        #expect(status == MediaStreamServerStatus(running: true, identifiers: [2_600_940_412]))
        #expect(MediaStreamServerStatus.parse(.dictionary(["running": .bool(false), "sessions": .array([])])) == MediaStreamServerStatus(running: false, identifiers: []))
    }

    @Test("the start request survives the XPC round trip with typed ports, the offer and the session UUID")
    func startRequestRoundTrip() throws {
        let session = UUID()
        let input = MediaStreamAction.startInput(receiverIP: "fd00::2", receiverPort: 55674, senderIP: "fd00::1", offer: Data([1, 2, 3]), session: session)
        #expect(MediaStreamValue(xpc: input.xpcObject) == input)
        #expect(input["receiverPort"] == .uint(55674))
        #expect(input["negotiatorOffer"] == .data(Data([1, 2, 3])))
        #expect(input["options"]?["avcMediaStreamOptionClientSessionID"]?["uuid"] == .uuid(session))
        #expect(input["type"] == .string("video"))
    }

    @Test("a stop names only this session, never every session on the device")
    func stopRequest() {
        let input = MediaStreamAction.stopInput(identifier: 7)
        #expect(input["stopAll"] == .bool(false))
        #expect(input["identifiers"] == .array([.uint(7)]))
    }

    @Test("the receiver binds the tunnel interface sharing the device's prefix, never a LAN interface or another tunnel")
    func tunnelEndpoint() {
        let interfaces = [
            TunnelEndpoint.Interface(name: "en0", address: "fd91:a2af:5418::9"),
            TunnelEndpoint.Interface(name: "utun10", address: "fdb7:55bd:3d39::2"),
            TunnelEndpoint.Interface(name: "utun9", address: "fd91:a2af:5418::1"),
            TunnelEndpoint.Interface(name: "utun9", address: "fd91:a2af:5418::2"),
        ]
        #expect(TunnelEndpoint.host(forDevice: "fd91:a2af:5418::1", among: interfaces) == TunnelEndpoint.Interface(name: "utun9", address: "fd91:a2af:5418::2"))
        #expect(TunnelEndpoint.host(forDevice: "fd12:3456:789a::1", among: interfaces) == nil)
        #expect(TunnelEndpoint.host(forDevice: "<scrubbed>", among: interfaces) == nil)
    }

    @Test("the frame slot keeps the newest frame and drops one whose timestamp does not advance")
    func latestFrameSlot() {
        var slot = LatestFrameSlot<String>()
        let accepted = [
            slot.offer("a", timestamp: 1),
            slot.offer("b", timestamp: 2),
            slot.offer("late", timestamp: 1.5),
            slot.offer("same", timestamp: 2),
            slot.offer("invalid", timestamp: .nan),
        ]
        #expect(accepted == [true, true, false, false, false])
        #expect(slot.frame == "b")
        #expect(slot.received == 2)
    }

    @Test("the frame slot settles only once its frames span the settle time, counting from the first accepted frame")
    func latestFrameSlotSettles() {
        var slot = LatestFrameSlot<String>()
        #expect(!slot.settled)
        slot.offer("first", timestamp: 10)
        #expect(!slot.settled)
        slot.offer("stale", timestamp: 9)
        slot.offer("early", timestamp: 10 + LatestFrameSlot<String>.settleSeconds / 2)
        #expect(!slot.settled)
        slot.offer("late", timestamp: 10 + LatestFrameSlot<String>.settleSeconds)
        #expect(slot.settled)
        #expect(slot.frame == "late")
    }

    @Test("a frame request waits for the stream to settle, takes an unsettled frame once its time is up, and fails with none", arguments: [
        (true, true, false, FrameWait.serve), (true, false, false, .wait), (true, false, true, .serve),
        (false, false, false, .wait), (false, true, false, .wait), (false, false, true, .fail),
    ])
    func frameWait(hasFrame: Bool, settled: Bool, pastDeadline: Bool, next: FrameWait) {
        #expect(FrameWait.next(hasFrame: hasFrame, settled: settled, pastDeadline: pastDeadline) == next)
    }

    @Test("only datagrams from the device's tunnel address are taken as the stream's sender")
    func streamSender() throws {
        let device = try #require(IOSDeviceScreenStream.ipv6Address("fd2b:1d9c:22c3::1%utun4"))
        func peer(_ literal: String) throws -> sockaddr_in6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = try #require(IOSDeviceScreenStream.ipv6Address(literal))
            return address
        }
        #expect(IOSDeviceScreenStream.isSender(try peer("fd2b:1d9c:22c3::1"), device))
        #expect(!IOSDeviceScreenStream.isSender(try peer("fd2b:1d9c:22c3::2"), device))
        #expect(IOSDeviceScreenStream.ipv6Address("10.0.0.1") == nil)
    }

    @Test("a listed device carries its tunnel address only when it is an IPv6 literal")
    func tunnelAddress() throws {
        func device(_ address: String) throws -> DevicectlDevice? {
            let json = """
            {"info": {"outcome": "success"}, "result": {"devices": [
              {"properties": {"hardware": {"platform": "iPadOS", "reality": "physical", "udid": "00008132-0000000000000001"},
                              "connection": {"state": "connected", "transportType": "wired", "tunnelIPAddressString": "\(address)"}}}
            ]}}
            """
            return try DevicectlDeviceList.parse(Data(json.utf8)).devices.first
        }
        #expect(try device("fd91:a2af:5418::1")?.tunnelAddress == "fd91:a2af:5418::1")
        #expect(try device("<scrubbed>")?.tunnelAddress == nil)
    }
}
