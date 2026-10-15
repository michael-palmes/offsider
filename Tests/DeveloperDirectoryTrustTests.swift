import Foundation
import OffsiderCore
import Testing

/// A fake Xcode layout under a temporary folder, removed by the caller.
private func makeFakeXcode(named name: String = "Xcode.app") throws -> (root: String, developer: String, app: String) {
    let temporary = DeveloperDirectoryTrust.realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
    let root = (temporary as NSString).appendingPathComponent("offsider-trust-\(UUID().uuidString)")
    let app = (root as NSString).appendingPathComponent(name)
    let developer = (app as NSString).appendingPathComponent("Contents/Developer")
    try FileManager.default.createDirectory(atPath: developer, withIntermediateDirectories: true)
    return (root, developer, app)
}

/// Counts validations and answers with `trusted`.
private final class ValidatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    let trusted: Bool

    init(trusted: Bool) {
        self.trusted = trusted
    }

    var calls: [String] { lock.withLock { seen } }

    func validate(_ app: String) -> Bool {
        lock.withLock { seen.append(app) }
        return trusted
    }
}

@Suite("Developer directory trust")
struct DeveloperDirectoryTrustTests {
    @Test("only <name>.app/Contents/Developer is the shape of an Xcode developer directory", arguments: [
        ("/Applications/Xcode.app/Contents/Developer", "/Applications/Xcode.app"),
        ("/Users/me/Xcode-beta.app/Contents/Developer", "/Users/me/Xcode-beta.app"),
        ("/Library/Developer/CommandLineTools", nil),
        ("/Applications/Xcode.app/Contents", nil),
        ("/Applications/Xcode/Contents/Developer", nil),
        ("/.app/Contents/Developer", nil),
        ("/tmp", nil),
    ] as [(String, String?)])
    func shape(path: String, app: String?) {
        #expect(DeveloperDirectoryTrust.appBundle(of: path) == app)
    }

    @Test("a folder outside an app bundle is refused without asking the validator, naming the path and DEVELOPER_DIR")
    func notInAppBundle() throws {
        let fake = try makeFakeXcode()
        defer { try? FileManager.default.removeItem(atPath: fake.root) }
        let probe = ValidatorProbe(trusted: true)
        let trust = DeveloperDirectoryTrust(validator: { probe.validate($0) })

        let error = #expect(throws: UntrustedDeveloperDirectory.self) { try trust.require(fake.root, source: .environment) }
        #expect(error?.problem == .notInAppBundle)
        #expect(error?.reason == .xcodeUnusable)
        #expect(error?.failureMessage.hasPrefix("DEVELOPER_DIR points at \(fake.root), which is not inside an Apple-signed Xcode, so Offsider will not load simulator frameworks or run Xcode tools from it.") == true)
        #expect(error?.hint?.hasPrefix("sudo xcode-select -s /Applications/") == true)
        #expect(probe.calls.isEmpty)
        #expect(trust.evaluate("/nonexistent/Xcode.app/Contents/Developer") == .failure(.notInAppBundle))
    }

    @Test("an app the validator rejects is not_apple_signed, and the error names xcode-select when it chose the path")
    func notAppleSigned() throws {
        let fake = try makeFakeXcode()
        defer { try? FileManager.default.removeItem(atPath: fake.root) }
        let trust = DeveloperDirectoryTrust(validator: { _ in false })

        let error = #expect(throws: UntrustedDeveloperDirectory.self) { try trust.require(fake.developer, source: .xcodeSelect) }
        #expect(error?.problem == .notAppleSigned)
        #expect(error?.failureMessage.hasPrefix("xcode-select points at \(fake.developer), which is not inside an Apple-signed Xcode") == true)
    }

    @Test("a symlink is resolved before the shape and signature checks, so a link named like Xcode cannot stand in for one")
    func symlinkResolution() throws {
        let fake = try makeFakeXcode(named: "Real.app")
        defer { try? FileManager.default.removeItem(atPath: fake.root) }
        let link = (fake.root as NSString).appendingPathComponent("Xcode.app")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fake.app)
        let probe = ValidatorProbe(trusted: true)
        let trust = DeveloperDirectoryTrust(validator: { probe.validate($0) })

        let trusted = try trust.require((link as NSString).appendingPathComponent("Contents/Developer"), source: .xcodeSelect)
        #expect(trusted.resolved == fake.developer)
        #expect(trusted.app == fake.app)
        #expect(probe.calls == [fake.app])

        let plain = (fake.root as NSString).appendingPathComponent("plain")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let disguised = (fake.root as NSString).appendingPathComponent("Disguised.app")
        try FileManager.default.createDirectory(atPath: (disguised as NSString).appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: (disguised as NSString).appendingPathComponent("Contents/Developer"), withDestinationPath: plain)
        #expect(trust.evaluate((disguised as NSString).appendingPathComponent("Contents/Developer")) == .failure(.notInAppBundle))
    }

    @Test("each resolved path is validated once per process, whatever spelling reaches it")
    func caching() throws {
        let fake = try makeFakeXcode()
        defer { try? FileManager.default.removeItem(atPath: fake.root) }
        let probe = ValidatorProbe(trusted: false)
        let trust = DeveloperDirectoryTrust(validator: { probe.validate($0) })

        for spelling in [fake.developer, fake.developer + "/", (fake.app as NSString).appendingPathComponent("Contents/../Contents/Developer")] {
            #expect(trust.evaluate(spelling) == .failure(.notAppleSigned))
        }
        #expect(probe.calls.count == 1)
    }

    @Test("the selected Xcode on this Mac is in an Apple-signed app, checked in well under a second")
    func liveXcodePasses() async throws {
        let result = try await ProcessCapture.run(executable: "/usr/bin/xcode-select", arguments: ["-p"], environment: ProcessInfo.processInfo.environment, timeout: 5)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(result.status == 0 && DeveloperDirectoryTrust.appBundle(of: DeveloperDirectoryTrust.realPath(path) ?? "") != nil)
        let started = Date()
        let trusted = try DeveloperDirectoryTrust().require(path, source: .xcodeSelect)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(trusted.app.hasSuffix(".app"))
    }
}

@Suite("Code signature check")
struct CodeSignatureCheckTests {
    @Test("a system binary satisfies anchor apple")
    func systemBinary() throws {
        try CodeSignatureCheck.validate(path: "/bin/ls", requirement: "anchor apple", resources: false)
        #expect(CodeSignatureCheck.satisfies(path: "/usr/bin/xcode-select", requirement: "anchor apple", resources: true))
    }

    @Test("a copy of a system binary still passes, and one with a changed code byte does not")
    func changedCopy() throws {
        let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("offsider-codesign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        var data = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
        try data.write(to: copy)
        #expect(CodeSignatureCheck.satisfies(path: copy.path, requirement: "anchor apple", resources: false))

        // A byte in a signed code page of every slice, at the offsets a universal binary's fat header names.
        func word(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        let fat = data.prefix(4) == Data([0xCA, 0xFE, 0xBA, 0xBE])
        let slices = fat ? (0..<word(4)).map { word(8 + $0 * 20 + 8) } : [0]
        for slice in slices { data[slice + 0x2000] ^= 0xFF }
        try data.write(to: copy)

        #expect(!CodeSignatureCheck.satisfies(path: copy.path, requirement: "anchor apple", resources: false))
        #expect(throws: CodeSignatureCheck.Failure.self) { try CodeSignatureCheck.validate(path: copy.path, requirement: "anchor apple", resources: false) }
    }

    @Test("an unsigned file fails, and so does a requirement for a team that did not sign it")
    func unsignedAndWrongTeam() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("offsider-unsigned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("#!/bin/sh\n".utf8).write(to: file)
        #expect(!CodeSignatureCheck.satisfies(path: file.path, requirement: "anchor apple", resources: false))
        #expect(!CodeSignatureCheck.satisfies(path: "/bin/ls", requirement: CodeSignatureCheck.teamRequirement("ABCDE12345"), resources: false))
        #expect(CodeSignatureCheck.teamRequirement("ABCDE12345") == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }
}

@Suite("Doctor xcode.trust")
struct XcodeTrustDoctorRuleTests {
    static let inApplications = TrustedDeveloperDirectory(resolved: "/Applications/Xcode.app/Contents/Developer", app: "/Applications/Xcode.app")
    static let elsewhere = TrustedDeveloperDirectory(resolved: "/Users/me/Xcode.app/Contents/Developer", app: "/Users/me/Xcode.app")

    @Test("Apple-signed in /Applications passes; elsewhere or through DEVELOPER_DIR warns; not Apple's fails with the xcode-select fix", arguments: [
        (Result<TrustedDeveloperDirectory, UntrustedDeveloperDirectory.Problem>.success(inApplications), DeveloperDirectorySource.xcodeSelect, CheckStatus.pass),
        (.success(inApplications), .environment, .warn),
        (.success(elsewhere), .xcodeSelect, .warn),
        (.failure(.notAppleSigned), .xcodeSelect, .fail),
        (.failure(.notInAppBundle), .environment, .fail),
    ])
    func verdicts(result: Result<TrustedDeveloperDirectory, UntrustedDeveloperDirectory.Problem>, source: DeveloperDirectorySource, status: CheckStatus) {
        let verdict = DoctorRules.xcodeTrust(result, path: "/X/Contents/Developer", source: source, suggestion: XcodeSuggestion(developerDirectory: "/Applications/Xcode-27.0.app/Contents/Developer"))
        #expect(verdict.status == status)
        if status == .fail {
            #expect(verdict.detail.contains("/X/Contents/Developer (\(source.rawValue))"))
            #expect(verdict.hint == "sudo xcode-select -s /Applications/Xcode-27.0.app/Contents/Developer")
        }
        if status == .pass { #expect(verdict.hint == nil) }
    }

    @Test("xcode.trust follows xcode.developer-dir in the contract order")
    func order() {
        let ids = DoctorCheckID.allCases.map(\.rawValue)
        #expect(ids.firstIndex(of: "xcode.trust") == ids.firstIndex(of: "xcode.developer-dir").map { $0 + 1 })
    }
}
