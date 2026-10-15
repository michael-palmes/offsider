import Foundation
import OffsiderCore
import Testing
@testable import OffsiderIOSDevice

@Suite("Private API guard")
struct PrivateAPIGuardTests {
    @Test("frame offsets are ignored when comparing type encodings")
    func stripped() {
        #expect(PrivateAPIGuard.strippedEncoding("@28@0:8@16I24") == "@@:@I")
        #expect(PrivateAPIGuard.strippedEncoding("I32@0:8@16^@24") == "I@:@^@")
        #expect(PrivateAPIGuard.strippedEncoding("{CGRect={CGPoint=dd}{CGSize=dd}}80@0:8q16") == "{CGRect={CGPoint=dd}{CGSize=dd}}@:q")
    }

    @Test("array sizes, bitfield widths, quoted class names and struct names keep their digits")
    func keepsSizes() {
        #expect(PrivateAPIGuard.strippedEncoding("v40@0:8[4i]16") == "v@:[4i]")
        #expect(PrivateAPIGuard.strippedEncoding("v40@0:8[4i]16") != PrivateAPIGuard.strippedEncoding("v56@0:8[8i]16"))
        #expect(PrivateAPIGuard.strippedEncoding("v20@0:8{flags=b3b5}16") == "v@:{flags=b3b5}")
        #expect(PrivateAPIGuard.strippedEncoding("v20@0:8{flags=b3b5}16") != PrivateAPIGuard.strippedEncoding("v20@0:8{flags=b4b4}16"))
        #expect(PrivateAPIGuard.strippedEncoding(#"@"_TtC12SimulatorKit5Thing"16@0:8"#) == #"@"_TtC12SimulatorKit5Thing"@:"#)
        #expect(PrivateAPIGuard.strippedEncoding("v24@0:8{Point2D=dd}16") == "v@:{Point2D=dd}")
    }

    @Test("a method whose types match passes; a changed or missing one fails as xcode_unusable naming the selector")
    func requireMethod() throws {
        try PrivateAPIGuard.requireMethod(NSString.self, NSSelectorFromString("length"), encoding: "Q16@0:8", framework: "Foundation")
        let changed = #expect(throws: PrivateAPIChanged.self) {
            try PrivateAPIGuard.requireMethod(NSString.self, NSSelectorFromString("length"), encoding: "I@:", framework: "SimulatorKit")
        }
        #expect(changed?.reason == .xcodeUnusable)
        #expect(changed?.failureMessage == "This Xcode's SimulatorKit changed length; update Offsider.")
        #expect(throws: PrivateAPIChanged.self) {
            try PrivateAPIGuard.requireMethod(NSString.self, NSSelectorFromString("noSuchSelector"), encoding: "v@:", framework: "SimulatorKit")
        }
    }

    @Test("a message checked against a protocol fails when the declared types differ, even if the object answers")
    func requireMessage() throws {
        let object = NSString(string: "x")
        #expect(throws: PrivateAPIChanged.self) {
            try PrivateAPIGuard.requireMessage(to: object, NSSelectorFromString("hash"), encoding: "I@:", protocol: "NSObject", framework: "SimulatorKit")
        }
        try PrivateAPIGuard.requireMessage(to: object, NSSelectorFromString("hash"), encoding: "Q16@0:8", protocol: "NSObject", framework: "Foundation")
        #expect(throws: PrivateAPIChanged.self) {
            try PrivateAPIGuard.requireMessage(to: object, NSSelectorFromString("hash"), encoding: "Q@:", protocol: "NoSuchProtocol", framework: "SimulatorKit")
        }
    }

    @Test("a selector with no recorded encoding is refused as xcode_unusable naming it")
    func unrecorded() throws {
        #expect(try PrivateAPIGuard.recordedEncoding("start", in: ["start": "v@:"], framework: "AVConference") == "v@:")
        let error = #expect(throws: PrivateAPIUnrecorded.self) {
            try PrivateAPIGuard.recordedEncoding("stop", in: ["start": "v@:"], framework: "AVConference")
        }
        #expect(error?.reason == .xcodeUnusable)
        #expect(error?.failureMessage == "Offsider has no recorded types for AVConference's stop, so it will not call it; update Offsider.")
    }

    @Test("every selector the media stream casts has a recorded encoding")
    func mediaStreamSelectorsRecorded() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OffsiderIOSDevice/Stream/CoreDeviceMediaStream.swift")
        let text = try String(decoding: Data(contentsOf: source), as: UTF8.self)
        let used = text.split(separator: "\n").filter { $0.contains("Runtime.implementation(") }
            .compactMap { $0.firstMatch(of: #/MediaStreamSymbols\.(\w+), as:/#).map { String($0.output.1) } }
        let selectors: [String: String] = [
            "alloc": MediaStreamSymbols.alloc, "negotiatorInit": MediaStreamSymbols.negotiatorInit, "createOffer": MediaStreamSymbols.createOffer,
            "offer": MediaStreamSymbols.offer, "setAnswer": MediaStreamSymbols.setAnswer, "configuration": MediaStreamSymbols.configuration,
            "initOptions": MediaStreamSymbols.initOptions, "videoStreamInit": MediaStreamSymbols.videoStreamInit, "setDelegate": MediaStreamSymbols.setDelegate,
            "configure": MediaStreamSymbols.configure, "start": MediaStreamSymbols.start, "stop": MediaStreamSymbols.stop,
            "streamOutput": MediaStreamSymbols.streamOutput, "setStreamOutput": MediaStreamSymbols.setStreamOutput, "streamToken": MediaStreamSymbols.streamToken,
            "streamOutputInit": MediaStreamSymbols.streamOutputInit,
        ]
        #expect(!used.isEmpty)
        for name in used {
            let selector = try #require(selectors[name], "\(name) is cast but not listed here")
            #expect(MediaStreamSymbols.encodings[selector] != nil, "\(selector) has no recorded encoding")
        }
        #expect(Set(selectors.values).isSubset(of: Set(MediaStreamSymbols.encodings.keys)))
    }
}
