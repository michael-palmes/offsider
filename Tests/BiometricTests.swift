import Foundation
@testable import OffsiderCore
import Testing

@Suite("Biometric")
struct BiometricTests {
    @Test("Face ID devices post the pearl keys and Touch ID devices the fingerTouch keys")
    func notificationKeys() {
        #expect(BiometricControl.notification(.match, modality: .face) == "com.apple.BiometricKit_Sim.pearl.match")
        #expect(BiometricControl.notification(.noMatch, modality: .face) == "com.apple.BiometricKit_Sim.pearl.nomatch")
        #expect(BiometricControl.notification(.match, modality: .finger) == "com.apple.BiometricKit_Sim.fingerTouch.match")
        #expect(BiometricControl.notification(.noMatch, modality: .finger) == "com.apple.BiometricKit_Sim.fingerTouch.nomatch")
    }

    @Test("the modality follows the device type", arguments: [
        ("iPhone 17", BiometricModality.face), ("iPhone SE (3rd generation)", .finger), ("iPad Air 13-inch (M3)", .finger),
        ("iPad Pro 13-inch (M5)", .face), ("iPad mini (A17 Pro)", .finger), ("iPhone Duo", .face),
    ])
    func modality(name: String, expected: BiometricModality) {
        #expect(BiometricControl.defaultModality(deviceTypeName: name) == expected)
    }

    @Test("enrol sets the enrolment flag then posts the change")
    func enrolArguments() {
        #expect(BiometricControl.iosSetEnrolmentArguments(udid: "SIM", enrolled: true) == [
            ["simctl", "spawn", "SIM", "notifyutil", "-s", "com.apple.BiometricKit.enrollmentChanged", "1"],
            ["simctl", "spawn", "SIM", "notifyutil", "-p", "com.apple.BiometricKit.enrollmentChanged"],
        ])
        #expect(BiometricControl.iosSetEnrolmentArguments(udid: "SIM", enrolled: false)[0].last == "0")
        #expect(BiometricControl.iosReadEnrolmentArguments(udid: "SIM") == ["simctl", "spawn", "SIM", "notifyutil", "-g", "com.apple.BiometricKit.enrollmentChanged"])
    }

    @Test("US spellings are accepted for enrol and unenrol")
    func spellings() {
        #expect(BiometricAction.parse("enroll") == .enrol)
        #expect(BiometricAction.parse("Unenroll") == .unenrol)
        #expect(BiometricAction.parse("no-match") == .noMatch)
        #expect(BiometricAction.parse("nomatch") == nil)
    }

    @Test("Android enrolment reads from the fingerprint dump, unknown when it is missing")
    func androidEnrolled() {
        #expect(BiometricControl.parseAndroidEnrolled(#"{"service":"FingerprintProvider/default","prints":[{"id":0,"count":0,"accept":0}]}"#) == false)
        #expect(BiometricControl.parseAndroidEnrolled(#"{"prints":[{"id":0,"count":2}]}"#) == true)
        #expect(BiometricControl.parseAndroidEnrolled("Can't find service: fingerprint") == nil)
    }

    @Test("each dump shape reads its current user's prints", arguments: [
        ("one sensor with prints", FingerprintDumpFixtures.oneSensorEnrolled, true as Bool?),
        ("one sensor, none", FingerprintDumpFixtures.oneSensorEmpty, false),
        ("a second sensor with the print", FingerprintDumpFixtures.twoSensors, true),
        ("profiles with no prints of their own", FingerprintDumpFixtures.profileUsers, true),
        ("before sensor headers", FingerprintDumpFixtures.legacy, true),
        ("the owner, by the status script", FingerprintDumpFixtures.status(user: "0", FingerprintDumpFixtures.twoUsers), true),
        ("a second user in front", FingerprintDumpFixtures.status(user: "10", FingerprintDumpFixtures.twoUsers), false),
        ("a current user the dump leaves out", FingerprintDumpFixtures.status(user: "11", FingerprintDumpFixtures.twoUsers), nil),
        ("no current user and two users listed", FingerprintDumpFixtures.status(user: "Unknown command: get-current-user", FingerprintDumpFixtures.twoUsers), nil),
        ("no current user and one user listed", FingerprintDumpFixtures.status(user: "", FingerprintDumpFixtures.oneSensorEnrolled), true),
    ])
    func androidShapes(name: String, dump: String, expected: Bool?) {
        #expect(BiometricControl.parseAndroidEnrolled(dump) == expected, "\(name)")
    }

    @Test("anything the parser cannot read is unknown, never not enrolled", arguments: [
        "",
        "Permission Denial: can't dump fingerprint from pid=1234, uid=2000",
        "Dumping for sensorId: 0, provider: FingerprintProvider\nFps state: 0\n",
        #"{"service":"FingerprintProvider","prints":[{"id":0,"count":0"#,
        #"{"service":"FingerprintProvider","prints":[]}"#,
        #"{"service":"FingerprintProvider","prints":[{"id":0}]}"#,
        #"{"service":"FingerprintProvider","prints":[{"id":0,"count":true}]}"#,
        #"{"service":"FingerprintProvider","prints":[{"id":0,"count":-1}]}"#,
        #"{"service":"FingerprintProvider","prints":[{"id":0,"count":1.5}]}"#,
        #"{"service":"FingerprintProvider","prints":[{"id":0,"count":0},{"id":0,"count":0}]}"#,
        #"{"service":"FingerprintProvider","prints":[{"id":"0","count":"2"}]}"#,
        "No \"prints\" recorded",
    ])
    func androidUnreadable(dump: String) {
        #expect(BiometricControl.parseAndroidEnrolled(dump) == nil)
    }

    @Test("an unreadable sensor makes none read as unknown, while a print on another still counts")
    func androidMixedSensors() {
        let broken = "Dumping for sensorId: 1, provider: FingerprintProvider\n{\"service\":\"x\",\"prints\":[{\"id\":0,\"count\"\n"
        #expect(BiometricControl.parseAndroidEnrolled(FingerprintDumpFixtures.oneSensorEmpty + broken) == nil)
        #expect(BiometricControl.parseAndroidEnrolled(broken + FingerprintDumpFixtures.oneSensorEnrolled) == true)
    }

    @Test("a sensor line past the size cap is left unread")
    func androidOversizedLine() {
        let padding = String(repeating: "x", count: BiometricControl.maximumSensorLineBytes)
        let line = #"{"service":"\#(padding)","prints":[{"id":0,"count":0}]}"#
        #expect(BiometricControl.parseAndroidEnrolled(line) == nil)
    }

    @Test("the status script reads the current user and the dump in one shell, changing nothing")
    func androidStatusScript() {
        #expect(BiometricControl.androidStatusScript == "cmd activity get-current-user 2>/dev/null; echo __offsider_fingerprint__; dumpsys fingerprint; true")
    }
}
