import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

@Suite("posture notices")
struct PostureNoticeTests {
    static func result(_ current: Posture, previous: Posture?, state: String? = "CLOSE") -> PostureCommand.Result {
        PostureCommand.Result(current: current, previous: previous, screen: nil, platform: .android, state: state)
    }

    @Test("folding a USB phone names the reset that undoes it, for a person and an agent")
    func phoneNamesReset() throws {
        let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)
        let notices = PostureCommand.notices(Self.result(.closed, previous: .open), set: true, on: phone)
        #expect(notices.count == 1)
        #expect("\(notices)".contains("offsider posture reset --device R58M123ABC"))
    }

    @Test("an emulator, a read and a posture already in place add no note")
    func noNoteOtherwise() {
        let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)
        #expect(PostureCommand.notices(Self.result(.closed, previous: .open), set: true, on: DeviceID(rawValue: "emulator-5554", platform: .android)).isEmpty)
        #expect(PostureCommand.notices(Self.result(.closed, previous: nil), set: false, on: phone).isEmpty)
        #expect(PostureCommand.notices(Self.result(.closed, previous: .closed), set: true, on: phone).isEmpty)
    }
}
