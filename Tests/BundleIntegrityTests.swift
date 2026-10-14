import Foundation
@testable import Offsider
import OffsiderCore
import Testing

@Suite("Bundle integrity")
struct BundleIntegrityTests {
    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Offsider/Resources")

    @Test("every bundled resource has a digest compiled into this build, and every digest names a bundled file")
    func digestsCoverTheBundle() throws {
        let root = try #require(Bundle.module.resourceURL)
        var found: Set<String> = []
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if relative.contains("/xcuserdata/") || relative.hasSuffix(".DS_Store") { continue }
            found.insert(relative)
        }
        #expect(found == Set(BundleDigests.files.keys))
        #expect(found.contains("helper/offsider-helper.dex"))
        #expect(found.contains("skills/offsider/SKILL.md"))
    }

    @Test("a bundled file is read when it matches, and refused with install_damaged when it does not")
    func verifiesBeforeReading() throws {
        let skill = try BundleIntegrity.verifiedData("skills/offsider/SKILL.md")
        #expect(String(decoding: skill, as: UTF8.self).hasPrefix("---"))

        var tampered = BundleDigests.files
        tampered["skills/offsider/references/errors.md"] = String(repeating: "f", count: 64)
        let error = #expect(throws: CLIError.self) {
            try BundleIntegrity.verifiedData("skills/offsider/references/errors.md", digests: tampered)
        }
        #expect(error?.reason == .installDamaged)
        #expect(error?.userFacingDescription.contains("references/errors.md") == true)
        #expect(error?.hint == "brew reinstall offsider")

        let unknown = #expect(throws: CLIError.self) { try BundleIntegrity.verifiedData("skills/offsider/extra.md") }
        #expect(unknown?.reason == .installDamaged)
    }

    @Test("a symlinked resource is refused even when its target has the right bytes")
    func refusesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-bundle-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Contents/Resources/skills/offsider", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let real = Self.resources.appendingPathComponent("skills/offsider/SKILL.md")
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("SKILL.md"), withDestinationURL: real)
        let bundle = try #require(Bundle(url: root))

        let error = #expect(throws: CLIError.self) {
            try BundleIntegrity.verifiedData("skills/offsider/SKILL.md", in: bundle)
        }
        #expect(error?.reason == .installDamaged)
    }

    @Test("doctor's install.bundle check passes on this build and names the first file that differs")
    func doctorCheck() {
        let healthy = BundleIntegrity.doctorCheck()
        #expect(healthy.id == .installBundle)
        #expect(healthy.status == .pass)

        var tampered = BundleDigests.files
        tampered["helper/manifest.json"] = String(repeating: "0", count: 64)
        let broken = BundleIntegrity.doctorCheck(digests: tampered)
        #expect(broken.status == .fail)
        #expect(broken.detail.contains("helper/manifest.json"))
        #expect(broken.hint == "brew reinstall offsider")
    }

    @Test("runner digests are keyed by their path under runner/")
    func runnerFiles() {
        let files = BundleIntegrity.runnerFiles(digests: ["runner/project.yml": "a", "helper/manifest.json": "b"])
        #expect(files == ["project.yml": "a"])
    }
}
