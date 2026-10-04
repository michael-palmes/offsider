import Foundation
import OffsiderCore
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
}
