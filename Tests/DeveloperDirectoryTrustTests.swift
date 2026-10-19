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

/// Counts validations and answers with `trusted`, else not Apple-signed.
private final class ValidatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    let trusted: Bool

    init(trusted: Bool) {
        self.trusted = trusted
    }

    var calls: [String] { lock.withLock { seen } }

    func validate(_ app: String) -> UntrustedDeveloperDirectory.Problem? {
        lock.withLock { seen.append(app) }
        return trusted ? nil : .notAppleSigned
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
        #expect(error?.failureMessage.hasPrefix("DEVELOPER_DIR points at \(fake.root), which is not the Contents/Developer folder of an Xcode app, so Offsider will not load simulator frameworks or run Xcode tools from it.") == true)
        let hint = try #require(error?.hint)
        #expect(hint.hasPrefix("sudo xcode-select -s /Applications/") || hint == XcodeSuggestion.install)
        #expect(probe.calls.isEmpty)
        #expect(trust.evaluate("/nonexistent/Xcode.app/Contents/Developer") == .failure(.notInAppBundle))
    }

    @Test("the refusal says why, and names xcode-select when it chose the path", arguments: [
        (UntrustedDeveloperDirectory.Problem.notAppleSigned, "is in an app that Apple did not sign as Xcode"),
        (.unsigned, "is in an app with no code signature"),
        (.modified, "is in an app changed since it was signed"),
    ])
    func refusalSaysWhy(problem: UntrustedDeveloperDirectory.Problem, why: String) throws {
        let fake = try makeFakeXcode()
        defer { try? FileManager.default.removeItem(atPath: fake.root) }
        let trust = DeveloperDirectoryTrust(validator: { _ in problem })

        let error = #expect(throws: UntrustedDeveloperDirectory.self) { try trust.require(fake.developer, source: .xcodeSelect) }
        #expect(error?.problem == problem)
        #expect(error?.failureMessage.hasPrefix("xcode-select points at \(fake.developer), which \(why), so Offsider") == true)
        #expect(error?.hint?.contains(fake.root) == false)
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

    @Test("Apple's own signature passes, as Xcode from developer.apple.com has, on an app and a binary")
    func appleSignaturePasses() {
        #expect(DeveloperDirectoryTrust.check("/System/Applications/Calculator.app") == nil)
        #expect(DeveloperDirectoryTrust.check("/bin/ls") == nil)
    }

    @Test("unsigned, changed and someone else's signatures are each refused for what they are")
    func refusedSignatures() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("offsider-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unsigned = folder.appendingPathComponent("unsigned")
        try Data("#!/bin/sh\n".utf8).write(to: unsigned)
        #expect(DeveloperDirectoryTrust.check(unsigned.path) == .unsigned)

        let changed = folder.appendingPathComponent("changed")
        var data = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
        func word(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        let fat = data.prefix(4) == Data([0xCA, 0xFE, 0xBA, 0xBE])
        for slice in fat ? (0..<word(4)).map({ word(8 + $0 * 20 + 8) }) : [0] { data[slice + 0x2000] ^= 0xFF }
        try data.write(to: changed)
        #expect(DeveloperDirectoryTrust.check(changed.path) == .modified)

        let resigned = folder.appendingPathComponent("resigned")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: resigned.path)
        let signing = try await ProcessCapture.run(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", resigned.path], environment: [:], timeout: 30)
        try #require(signing.status == 0)
        #expect(DeveloperDirectoryTrust.check(resigned.path) == .notAppleSigned)
    }

    @Test("an Xcode from the Mac App Store passes as com.apple.dt.Xcode from Apple's team only, which anchor apple alone refused", .enabled(if: appStoreXcodeApp != nil))
    func appStoreXcodePasses() throws {
        let app = try #require(appStoreXcodeApp)
        let otherIdentifier = DeveloperDirectoryTrust.appStoreXcode.replacingOccurrences(of: "com.apple.dt.Xcode", with: "com.example.other")
        #expect(DeveloperDirectoryTrust.check(app) == nil)
        #expect(DeveloperDirectoryTrust.check(app, appStoreTeam: "ABCDE12345") == .notAppleSigned)
        #expect(!CodeSignatureCheck.satisfies(path: app, requirement: DeveloperDirectoryTrust.appleRequirement, resources: false))
        #expect(!CodeSignatureCheck.satisfies(path: app, requirement: otherIdentifier, resources: false))
        #expect(try CodeSignatureCheck.validate(path: app, requirement: DeveloperDirectoryTrust.appStoreXcode, resources: false) == DeveloperDirectoryTrust.appStoreXcodeTeam)
    }
}

/// The selected Xcode's app when the Mac App Store signed it, else nil.
private let appStoreXcodeApp: String? = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let app = DeveloperDirectoryTrust.realPath(path).flatMap(DeveloperDirectoryTrust.appBundle(of:)),
          CodeSignatureCheck.satisfies(path: app, requirement: DeveloperDirectoryTrust.appStoreXcode, resources: false) else { return nil }
    return app
}()

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

    static let installed = [XcodeBundle(path: "/Applications/Xcode-27.0.app", version: "27.0", appleSigned: true)]

    @Test("Apple-signed in /Applications passes; elsewhere or through DEVELOPER_DIR warns; not Apple's fails with the xcode-select fix", arguments: [
        (Result<TrustedDeveloperDirectory, UntrustedDeveloperDirectory.Problem>.success(inApplications), DeveloperDirectorySource.xcodeSelect, CheckStatus.pass),
        (.success(inApplications), .environment, .warn),
        (.success(elsewhere), .xcodeSelect, .warn),
        (.failure(.notAppleSigned), .xcodeSelect, .fail),
        (.failure(.notInAppBundle), .environment, .fail),
    ])
    func verdicts(result: Result<TrustedDeveloperDirectory, UntrustedDeveloperDirectory.Problem>, source: DeveloperDirectorySource, status: CheckStatus) {
        let verdict = DoctorRules.xcodeTrust(result, path: "/X/Contents/Developer", source: source, installed: Self.installed)
        #expect(verdict.status == status)
        if status == .fail {
            #expect(verdict.detail.contains("/X/Contents/Developer (\(source.rawValue))"))
            #expect(verdict.hint == "sudo xcode-select -s /Applications/Xcode-27.0.app/Contents/Developer")
        }
        if status == .pass { #expect(verdict.hint == nil) }
    }

    @Test("a refused Xcode is never the fix: the only one installed leaves the install as the hint")
    func refusedXcodeIsNotTheFix() {
        let bundles = [XcodeBundle(path: "/Applications/Xcode.app", version: "27.1", appleSigned: true)]
        let verdict = DoctorRules.xcodeTrust(.failure(.modified), path: "/Applications/Xcode.app/Contents/Developer", source: .xcodeSelect, installed: bundles)
        #expect(verdict.detail == "/Applications/Xcode.app/Contents/Developer (xcode-select) is in an app changed since it was signed, so Offsider will not use it")
        #expect(verdict.hint == XcodeSuggestion.install)
    }

    @Test("with no Xcode in /Applications, the warnings name the trusted one itself")
    func warningsWithNothingInstalled() {
        let environment = DoctorRules.xcodeTrust(.success(Self.elsewhere), path: Self.elsewhere.resolved, source: .environment, installed: [])
        #expect(environment.hint == "Unset DEVELOPER_DIR and select Xcode with sudo xcode-select -s /Users/me/Xcode.app/Contents/Developer.")
        let outside = DoctorRules.xcodeTrust(.success(Self.elsewhere), path: Self.elsewhere.resolved, source: .xcodeSelect, installed: [])
        #expect(outside.hint == "Move Xcode into /Applications, then run sudo xcode-select -s /Applications/Xcode.app/Contents/Developer.")
    }

    @Test("xcode.trust follows xcode.developer-dir in the contract order")
    func order() {
        let ids = DoctorCheckID.allCases.map(\.rawValue)
        #expect(ids.firstIndex(of: "xcode.trust") == ids.firstIndex(of: "xcode.developer-dir").map { $0 + 1 })
    }
}
