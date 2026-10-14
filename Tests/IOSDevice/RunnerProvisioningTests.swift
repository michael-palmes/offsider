import CryptoKit
import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

/// xcodebuild as the builder sees it: records each argument list and lays out a device build's products, or fails with `output`.
final class FakeXcodebuild: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var status: Int32 = 0
    var output = ""

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) throws -> ProcessCaptureResult {
        lock.withLock { recorded.append(arguments) }
        guard status == 0, let index = arguments.firstIndex(of: "-derivedDataPath") else {
            return ProcessCaptureResult(status: status, stdout: output, stderr: "")
        }
        let products = URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("Build/Products")
        let config = products.appendingPathComponent("Debug-iphoneos")
        let files = [
            config.appendingPathComponent("OffsiderRunnerHost.app/OffsiderRunnerHost"),
            config.appendingPathComponent("OffsiderRunnerUITests-Runner.app/OffsiderRunnerUITests-Runner"),
            config.appendingPathComponent("OffsiderRunnerUITests-Runner.app/PlugIns/OffsiderRunnerUITests.xctest/OffsiderRunnerUITests"),
            products.appendingPathComponent("OffsiderRunner_iphoneos27.0-arm64.xctestrun"),
        ]
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("built \(file.lastPathComponent)".utf8).write(to: file)
        }
        return ProcessCaptureResult(status: 0, stdout: "", stderr: "")
    }
}

/// Answers every signature check with `valid` and keeps the requirements it was asked.
final class FakeSignatures: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var valid: Bool

    init(valid: Bool = true) {
        self.valid = valid
    }

    var requirements: [String] { lock.withLock { asked } }

    func check(_ path: String, _ requirement: String) -> Bool {
        lock.withLock { asked.append(requirement) }
        return valid
    }
}

@Suite("iOS device runner provisioning")
struct RunnerProvisioningTests {
    static let team = "ABCDE12345"

    struct Fixture {
        let source: URL
        let cache: URL
        let xcodebuild = FakeXcodebuild()
        let signatures = FakeSignatures()
        let notices = LineSink()

        init() throws {
            source = try RunnerBuilderTests.sourceDirectory()
            cache = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-runner-cache-\(UUID().uuidString)")
        }

        func builder(environment: [String: String] = ["OFFSIDER_IOS_TEAM_ID": RunnerProvisioningTests.team], allowanceTeam: String? = nil, expected: [String: String]? = nil, registerDevice: Bool = false) -> XcodeRunnerBuilder {
            let xcodebuild = xcodebuild
            let signatures = signatures
            return XcodeRunnerBuilder(
                source: source, cacheRoot: cache, xcode: XcodeLocation(developerDirectory: "/Xcode.app/Contents/Developer", source: "test", version: "27.0", build: "27A266a"),
                environment: environment, signedInTeams: { ["AAAAA11111"] }, notice: notices.append, allowanceTeam: allowanceTeam,
                expectedSource: expected, registerDevice: registerDevice,
                xcodebuild: { try xcodebuild.run($0, $1, $2) }, signatureValid: { signatures.check($0, $1) }
            )
        }

        func digests() throws -> [String: String] {
            try XcodeRunnerBuilder.fileDigests(in: source)
        }

        func remove() {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cache)
        }
    }

    @Test("a normal build signs with the chosen team and prefix but never registers the device; the notice names both")
    func noRegistrationByDefault() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let build = try await fixture.builder(environment: ["OFFSIDER_IOS_TEAM_ID": Self.team, "OFFSIDER_IOS_RUNNER_PREFIX": "com.example.qa"]).build(for: .device(udid: "U"), deviceName: "iPhone")

        let arguments = try #require(fixture.xcodebuild.calls.first)
        #expect(arguments.contains("DEVELOPMENT_TEAM=\(Self.team)") && arguments.contains("-allowProvisioningUpdates"))
        #expect(arguments.contains("OFFSIDER_RUNNER_BUNDLE_PREFIX=com.example.qa"))
        #expect(!arguments.contains("-allowProvisioningDeviceRegistration"))
        #expect(fixture.notices.values.count == 1)
        #expect(fixture.notices.values.first?.contains("team \(Self.team)") == true && fixture.notices.values.first?.contains("com.example.qa.runner") == true)
        #expect(build.key == XcodeRunnerBuilder.key(sourceDigest: try XcodeRunnerBuilder.sourceDigest(of: fixture.source), xcodeBuild: "27A266a", team: Self.team, prefix: "com.example.qa", destination: .device(udid: "U")))
    }

    @Test("only registerDevice adds xcodebuild's device registration flag, and the allowance's team signs when the variable is unset")
    func registrationOnRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        _ = try await fixture.builder(environment: [:], allowanceTeam: "ZYXWV98765", registerDevice: true).build(for: .device(udid: "U"), deviceName: "iPhone")

        let arguments = try #require(fixture.xcodebuild.calls.first)
        #expect(arguments.contains("-allowProvisioningDeviceRegistration"))
        #expect(arguments.contains("DEVELOPMENT_TEAM=ZYXWV98765"))
    }

    @Test("xcodebuild's unregistered-device failure names runner build --register-device and Xcode's Devices window")
    func unregisteredDeviceHint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.status = 65
        fixture.xcodebuild.output = "error: Device \"iPhone\" isn't registered in your developer account. The device must be registered in order to be included in a provisioning profile."

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await fixture.builder().build(for: .device(udid: "U"), deviceName: "iPhone") }
        #expect(error?.reason == .runnerBuildFailed)
        #expect(error?.hint == "offsider runner build --device U --register-device")
        #expect(error?.message.contains("Xcode > Window > Devices and Simulators") == true)
    }

    @Test("a build records its products in a private products.json naming the device, team and prefix")
    func productsRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let build = try await fixture.builder().build(for: .device(udid: "U"), deviceName: "iPhone")

        let path = build.directory.appendingPathComponent("products.json").path
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
        let record = try #require(try RunnerProducts.read(in: build.directory))
        #expect(record.udid == "U" && record.team == Self.team && record.prefix == "com.mpalmes.offsider")
        #expect(record.products.keys.contains("Debug-iphoneos/OffsiderRunnerHost.app/OffsiderRunnerHost"))
        #expect(record.products.keys.contains("OffsiderRunner_iphoneos27.0-arm64.xctestrun"))
    }

    @Test("launch checks each installed bundle against the team's certificate and keeps a build that matches")
    func verifiedBuildKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let builder = fixture.builder()
        let build = try await builder.build(for: .device(udid: "U"), deviceName: "iPhone")

        let checked = try await builder.verifyForLaunch(build, for: .device(udid: "U"), deviceName: "iPhone")

        #expect(checked == build)
        #expect(fixture.xcodebuild.calls.count == 1)
        #expect(fixture.signatures.requirements == Array(repeating: "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.team)\"", count: 3))
    }

    @Test("a product changed after the build is deleted and rebuilt once before launch")
    func changedProductRebuilt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let builder = fixture.builder()
        let build = try await builder.build(for: .device(udid: "U"), deviceName: "iPhone")
        let host = build.directory.appendingPathComponent("derived/Build/Products/Debug-iphoneos/OffsiderRunnerHost.app/OffsiderRunnerHost")
        try Data("tampered".utf8).write(to: host)

        let rebuilt = try await builder.verifyForLaunch(build, for: .device(udid: "U"), deviceName: "iPhone")

        #expect(fixture.xcodebuild.calls.count == 2)
        #expect(rebuilt.key == build.key)
        #expect(try String(contentsOf: host, encoding: .utf8) == "built OffsiderRunnerHost")
        #expect(fixture.notices.values.contains { $0.contains("changed after it was built") })
    }

    @Test("products another team signed are rebuilt once, then refused as runner_build_failed and deleted")
    func wrongSignatureRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let builder = fixture.builder()
        let build = try await builder.build(for: .device(udid: "U"), deviceName: "iPhone")
        fixture.signatures.valid = false

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await builder.verifyForLaunch(build, for: .device(udid: "U"), deviceName: "iPhone") }

        #expect(error?.reason == .runnerBuildFailed)
        #expect(error?.message.contains("not signed by team \(Self.team)") == true)
        #expect(fixture.xcodebuild.calls.count == 2)
        #expect(!FileManager.default.fileExists(atPath: build.directory.path))
    }

    @Test("a cached build from before products.json is rebuilt before launch")
    func unrecordedBuildRebuilt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let builder = fixture.builder()
        let build = try await builder.build(for: .device(udid: "U"), deviceName: "iPhone")
        try FileManager.default.removeItem(at: build.directory.appendingPathComponent("products.json"))

        _ = try await builder.verifyForLaunch(build, for: .device(udid: "U"), deviceName: "iPhone")

        #expect(fixture.xcodebuild.calls.count == 2)
    }

    @Test("the cache key comes from the compiled-in digests, so a source folder that drifts still builds under this build's key")
    func keyFromExpectedDigests() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.digests()

        let build = try await fixture.builder(expected: expected).build(for: .device(udid: "U"), deviceName: "iPhone")

        #expect(build.key == XcodeRunnerBuilder.key(sourceDigest: XcodeRunnerBuilder.sourceDigest(files: expected), xcodeBuild: "27A266a", team: Self.team, destination: .device(udid: "U")))
        #expect(XcodeRunnerBuilder.sourceDigest(files: expected) == (try XcodeRunnerBuilder.sourceDigest(of: fixture.source)))
    }

    enum SourceDrift: String, CaseIterable {
        case changed, extra, missing, nameHoldingXcuserdata, symlink
    }

    @Test("Xcode's per-user state in the bundled source is removed from the copy, so the build runs without it")
    func xcuserdataScrubbed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.digests()
        let scheme = fixture.source.appendingPathComponent("OffsiderRunner.xcodeproj/xcuserdata/me.xcuserdatad/xcschemes/x.xcscheme")
        try FileManager.default.createDirectory(at: scheme.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<Scheme/>".utf8).write(to: scheme)
        try Data("finder".utf8).write(to: fixture.source.appendingPathComponent(".DS_Store"))

        let build = try await fixture.builder(expected: expected).build(for: .device(udid: "U"), deviceName: "iPhone")

        #expect(fixture.xcodebuild.calls.count == 1)
        let copy = build.directory.appendingPathComponent("source")
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("OffsiderRunner.xcodeproj/xcuserdata").path))
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent(".DS_Store").path))
        #expect(try XcodeRunnerBuilder.copiedEntries(in: copy) == expected.mapValues(Optional.some))
    }

    @Test("a runner source copy that differs from the compiled-in digests is removed and refused before xcodebuild runs", arguments: SourceDrift.allCases)
    func sourceDigestMismatch(drift: SourceDrift) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.digests()
        switch drift {
        case .changed: try Data("final class Changed {}\n".utf8).write(to: fixture.source.appendingPathComponent("UITests/RunnerTests.swift"))
        case .extra: try Data("extra".utf8).write(to: fixture.source.appendingPathComponent("UITests/Extra.swift"))
        case .missing: try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("project.yml"))
        case .nameHoldingXcuserdata: try Data("extra".utf8).write(to: fixture.source.appendingPathComponent("UITests/notxcuserdata.swift"))
        case .symlink: try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("UITests/Linked.swift"), withDestinationURL: fixture.source.appendingPathComponent("project.yml"))
        }

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await fixture.builder(expected: expected).build(for: .device(udid: "U"), deviceName: "iPhone") }

        #expect(error?.reason == .runnerBuildFailed)
        #expect(error?.message.contains("does not match this Offsider build. Reinstall Offsider: brew reinstall offsider") == true)
        #expect(fixture.xcodebuild.calls.isEmpty)
        let key = XcodeRunnerBuilder.key(sourceDigest: XcodeRunnerBuilder.sourceDigest(files: expected), xcodeBuild: "27A266a", team: Self.team, destination: .device(udid: "U"))
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent("\(key)/source").path))
    }
}

@Suite("iOS device runner clean-up")
struct RunnerCleanupTests {
    static func makeBuild(_ cache: URL, key: String, udid: String, prefix: String = "com.mpalmes.offsider") throws {
        let directory = cache.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("derived/Build/Products"), withIntermediateDirectories: true)
        try RunnerProducts.write(RunnerProductsRecord(udid: udid, team: "ABCDE12345", prefix: prefix, products: [:]), in: directory)
        FileManager.default.createFile(atPath: cache.appendingPathComponent("\(key).lock").path, contents: Data())
    }

    @Test("--clean uninstalls both runner apps for each prefix this device used, and deletes only its own builds and logs")
    func cleanDevice() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-runner-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.makeBuild(cache, key: "mine", udid: "UDID-A", prefix: "com.example.qa")
        try Self.makeBuild(cache, key: "theirs", udid: "UDID-B")
        let log = cache.appendingPathComponent("runner.log")
        try Data("log".utf8).write(to: log)
        let devicectl = FakeDevicectl(replies: [:])

        let report = await RunnerCleanup.clean(udid: "UDID-A", cacheRoot: cache, environmentPrefix: "com.mpalmes.offsider", devicectl: devicectl, logPaths: [log.path, cache.appendingPathComponent("absent.log").path])

        let uninstalls = devicectl.calls.filter { $0.starts(with: ["device", "uninstall", "app"]) }
        #expect(uninstalls.map { $0[5] } == [
            "com.mpalmes.offsider.runner.uitests.xctrunner", "com.mpalmes.offsider.runner",
            "com.example.qa.runner.uitests.xctrunner", "com.example.qa.runner",
        ])
        #expect(uninstalls.allSatisfy { $0[3] == "--device" && $0[4] == "UDID-A" })
        #expect(report.uninstalled.count == 4 && report.notUninstalled.isEmpty)
        #expect(report.removedBuilds == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("mine").path))
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("mine.lock").path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("theirs").path))
        #expect(report.removedLogs == [log.path])
        #expect(report.remains.contains("Only the Apple developer site"))
        #expect(report.remains.contains("com.example.qa.runner.uitests"))
    }

    @Test("an uninstall devicectl refuses is reported with its reason, and the rest of the clean-up still runs")
    func uninstallFailure() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-runner-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.makeBuild(cache, key: "mine", udid: "UDID-A")
        let devicectl = FakeDevicectl(replies: ["app": ProcessCaptureResult(status: 1, stdout: "", stderr: "The device is not connected.\nmore")])

        let report = await RunnerCleanup.clean(udid: "UDID-A", cacheRoot: cache, environmentPrefix: "com.mpalmes.offsider", devicectl: devicectl, logPaths: [])

        #expect(report.uninstalled.isEmpty)
        #expect(report.notUninstalled["com.mpalmes.offsider.runner"] == "The device is not connected.")
        #expect(report.removedBuilds == 1)
    }
}
