import Foundation
import Testing

@Suite("Third-party licences")
struct ThirdPartyLicencesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func text(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("every package in Package.resolved has an entry in THIRD_PARTY_LICENSES")
    func everyResolvedPackageListed() throws {
        let resolved = try JSONSerialization.jsonObject(with: Data(try Self.text("Package.resolved").utf8)) as? [String: Any]
        let pins = try #require(resolved?["pins"] as? [[String: Any]])
        let licences = try Self.text("THIRD_PARTY_LICENSES")

        #expect(pins.count > 1)
        for pin in pins {
            let location = try #require(pin["location"] as? String)
            let url = location.hasSuffix(".git") ? String(location.dropLast(4)) : location
            #expect(licences.contains(url), "No THIRD_PARTY_LICENSES entry for \(url)")
        }
    }

    @Test("the vendored emulator proto keeps its AOSP header, says it was modified, and is listed")
    func protoListed() throws {
        let proto = try Self.text("Sources/OffsiderAndroid/Grpc/Proto/emulator_controller.proto")
        #expect(proto.hasPrefix("// Copyright (C) 2018 The Android Open Source Project"))
        #expect(proto.contains("// Modified for Offsider: trimmed"))
        #expect(proto.contains("package android.emulation.control;"))
        #expect(try Self.text("THIRD_PARTY_LICENSES").contains("Android Emulator gRPC protocol definition (emulator_controller.proto)"))
    }
}
