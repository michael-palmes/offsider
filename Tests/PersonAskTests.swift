import Foundation
import OffsiderCore
import OffsiderIOSDevice
import Testing
@testable import Offsider

@MainActor
@Suite("Asking the user for a hands-on step")
struct PersonAskTests {
    private let handsOn: [FailureReason] = [
        .turnstileRequired, .deviceLocked, .deviceUntrusted, .developerModeOff, .uiAutomationOff, .deviceNotWired, .usbmuxUnavailable,
    ]

    private func summary(_ id: String, name: String, state: String = "Booted", os: String? = "iOS 26.4") -> DeviceSummary {
        DeviceSummary(id: id, platform: .ios, state: state, name: name, osVersion: os, deviceType: nil, kind: .simulator, connection: nil)
    }

    @Test("every hands-on failure asks for the step on the named device, as a request")
    func handsOnReasonsAsk() throws {
        for reason in handsOn {
            let ask = try #require(reason.personAsk, "\(reason.rawValue) has no ask")
            #expect(ask.hasPrefix("Can you "), "\(reason.rawValue): \(ask)")
            #expect(ask.contains(PersonAsk.devicePlaceholder), "\(reason.rawValue) names no device")
        }
    }

    @Test("a failure a command can clear asks nobody for anything")
    func otherReasonsDoNotAsk() {
        for reason in FailureReason.allCases where !handsOn.contains(reason) {
            #expect(reason.personAsk == nil, "\(reason.rawValue) asks for hands")
        }
    }

    @Test("an ask names the device, then its id, then plain words")
    func filling() {
        let ask = PersonAsk.tickTurnstile
        #expect(PersonAsk.filled(ask, name: "iPhone 17", id: "emulator-5554") == "Can you tick the Turnstile checkbox on iPhone 17?")
        #expect(PersonAsk.filled(ask, name: nil, id: "emulator-5554") == "Can you tick the Turnstile checkbox on emulator-5554?")
        #expect(PersonAsk.filled(ask, name: "  ", id: "emulator-5554") == "Can you tick the Turnstile checkbox on emulator-5554?")
        #expect(PersonAsk.filled(ask, name: nil, id: nil) == "Can you tick the Turnstile checkbox on the device?")
    }

    @Test("a device's name cannot hide text or run long in an ask")
    func nameIsCleaned() throws {
        let forged = PersonAsk.filled(PersonAsk.tickTurnstile, name: "Phone\u{1B}]52;c;eA==\u{07}\u{202E}", id: nil)
        #expect(!forged.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{07}" || $0 == "\u{202E}" })

        let long = PersonAsk.filled(PersonAsk.tickTurnstile, name: String(repeating: "x", count: 500), id: nil)
        #expect(long.count < 200)
    }

    @Test("a name the Mac runs once is enough; a second running device with it adds what tells them apart")
    func namingAmongTwins() {
        let device = summary("A", name: "iPhone 17")
        #expect(PersonAsk.name(of: "A", among: [device, summary("B", name: "iPad Air")]) == "iPhone 17")
        #expect(PersonAsk.name(of: "A", among: [device, summary("B", name: "iPhone 17", state: "Shutdown")]) == "iPhone 17")
        #expect(PersonAsk.name(of: "A", among: [device, summary("B", name: "iPhone 17", os: "iOS 18.6")]) == "iPhone 17 on iOS 26.4")
        #expect(PersonAsk.name(of: "A", among: [device, summary("B", name: "iPhone 17")]) == "iPhone 17 (A)")
        #expect(PersonAsk.name(of: "Z", among: [device]) == nil)
    }

    @Test("the JSON error carries the filled ask, and marks it as holding device text")
    func jsonCarriesTheAsk() {
        let error = LoginFlow.turnstileRequired(.visualChallenge, stage: .beforeTyping, audience: .agent)
        let payload = ErrorReporter.payload(for: error, deviceName: "iPhone 17")
        #expect(payload.jsonLine().contains(#""ask":"Can you solve the Turnstile challenge on iPhone 17?""#))
        #expect(payload.untrustedPaths().contains("error.ask"))
    }

    @Test("a refusal from any backend asks by its reason")
    func otherFailureTypesAsk() {
        let locked = IOSDeviceError(.locked, "The device is locked.")
        #expect(ErrorReporter.payload(for: locked, deviceName: "iPad Air").ask == "Can you unlock iPad Air?")
        let cable = IOSDeviceError.notOnUsbmux("iPad Air")
        #expect(ErrorReporter.payload(for: cable, deviceName: "iPad Air").ask == "Can you unplug and replug the cable on iPad Air?")
    }

    @Test("an error nobody's hands can clear prints exactly what it did before")
    func noAskKeepsTheShape() {
        let payload = ErrorPayload(reason: .selectorNotFound, message: "No match.")
        #expect(payload.jsonLine() == #"{"reason":"selector_not_found","message":"No match.","hint":null,"dispatched":null,"candidates":[]}"#)
        #expect(!payload.untrustedPaths().contains("error.ask"))
    }

    @Test("an agent's text output gets the ask on its own line, cleaned")
    func askLine() {
        #expect(ErrorReporter.askText(nil).isEmpty)
        #expect(ErrorReporter.askText("").isEmpty)
        #expect(ErrorReporter.askText("Can you unlock iPad Air?") == "Ask: Can you unlock iPad Air?\n")
        #expect(!ErrorReporter.askText("Can you\nforge this?").contains("\n" + "forge"))
    }
}
