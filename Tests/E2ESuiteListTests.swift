import Foundation
import Testing

@Suite("E2E suite lists")
struct E2ESuiteListTests {
    private static let testsFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// Suites a person runs another way, so no mode of `test-runner.sh` names them.
    private static let runAnotherWay: Set<String> = [
        "TreeGoldenCaptureTests", // Tests/Goldens/README.md, with OFFSIDER_GOLDENS_UPDATE=1
        "TreeGoldenRefreshTests", // the same variable, offline
    ]

    /// `@Suite` declarations in the test sources, each with the text of its traits.
    private static func suites() throws -> [String: String] {
        let files = try #require(FileManager.default.enumerator(at: testsFolder, includingPropertiesForKeys: nil))
        let declaration = #/@Suite\((.*?)\)\s*(?:@\w+\s+)*(?:(?:final|private|fileprivate|public)\s+)*(?:struct|class|enum|actor)\s+(\w+)/#.dotMatchesNewlines()
        var found: [String: String] = [:]
        for case let file as URL in files where file.pathExtension == "swift" {
            for match in try String(contentsOf: file, encoding: .utf8).matches(of: declaration) {
                found[String(match.2)] = String(match.1)
            }
        }
        return found
    }

    private static func isGated(_ traits: String) -> Bool {
        traits.contains(#/\bis\w*E2EEnabled\b|RNPlatform\.anyEnabled/#)
    }

    /// The code of `test-runner.sh`, without its comment lines.
    private static func runner() throws -> String {
        let url = testsFolder.deletingLastPathComponent().appendingPathComponent("test-runner.sh")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
    }

    /// Every suite the script names on its own in quotes: its lists and the modes that run one suite.
    private static func listed() throws -> Set<String> {
        Set(try runner().matches(of: #/"([A-Z]\w*Tests)"/#).map { String($0.1) })
    }

    /// The names in one of the script's top-level `NAME=( ... )` lists.
    private static func list(_ name: String) throws -> Set<String> {
        let source = try runner()
        let start = try #require(source.range(of: "\n\(name)=(\n"), "test-runner.sh has no \(name)")
        let end = try #require(source[start.upperBound...].range(of: "\n)"))
        return Set(source[start.upperBound..<end.lowerBound].matches(of: #/"(\w+)"/#).map { String($0.1) })
    }

    @Test("every suite gated on an E2E flag is in a run list of test-runner.sh")
    func gatedSuitesAreListed() throws {
        let gated = Set(try Self.suites().filter { Self.isGated($0.value) }.keys)
        #expect(gated.isSuperset(of: ["TapTests", "AndroidTapTests", "ReactNativeRowsTests", "FoldableTests", "IOSDeviceInputE2ETests"]), "the @Suite scan found too little")
        let missing = gated.subtracting(try Self.listed()).subtracting(Self.runAnotherWay)
        #expect(missing.isEmpty, "add these to a list in test-runner.sh, or to runAnotherWay with how they run: \(missing.sorted())")
    }

    @Test("a suite is in the list of the mode that turns its flag on, since any other mode skips it", arguments: [
        ("isE2EEnabled", "SIMULATOR_SUITES"), ("isAndroidE2EEnabled", "ANDROID_SUITES"), ("RNPlatform.anyEnabled", "RN_SUITES"),
    ])
    func suitesAreInTheirModesList(flag: String, list: String) throws {
        let gated = Set(try Self.suites().filter { $0.value.contains(flag) && !$0.value.contains("isRNDebugE2EEnabled") }.keys)
        #expect(!gated.isEmpty, "no suite is gated on \(flag)")
        let missing = gated.subtracting(try Self.list(list)).subtracting(Self.runAnotherWay)
        #expect(missing.isEmpty, "add these to \(list) in test-runner.sh: \(missing.sorted())")
    }

    @Test("every suite a list names exists, since a name that matches nothing passes")
    func listedSuitesExist() throws {
        let unknown = try Self.listed().subtracting(try Self.suites().keys)
        #expect(unknown.isEmpty, "test-runner.sh names suites that do not exist: \(unknown.sorted())")
    }

    @Test("every fuzz target has a seed folder and every seed folder a target, since the weekly job fails on a target with no seeds")
    func fuzzTargetsHaveSeeds() throws {
        let root = Self.testsFolder.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OffsiderFuzz/FuzzTargets.swift"), encoding: .utf8)
        let targets = Set(source.matches(of: #/^\s+"([a-z0-9-]+)": \w+,$/#.anchorsMatchLineEndings()).map { String($0.1) })
        #expect(targets.contains("android-notifications"), "the target scan found too little")
        let seeds = Self.testsFolder.appendingPathComponent("Fixtures/fuzz")
        let folders = try FileManager.default.contentsOfDirectory(atPath: seeds.path).filter { !$0.hasPrefix(".") }
        #expect(Set(folders) == targets)
        for folder in folders {
            #expect(try !FileManager.default.contentsOfDirectory(atPath: seeds.appendingPathComponent(folder).path).isEmpty, "\(folder) has no seeds")
        }
    }

    @Test("a suite run another way is still gated, so the exception cannot go stale")
    func exceptionsAreGated() throws {
        let suites = try Self.suites()
        for suite in Self.runAnotherWay {
            #expect(suites[suite].map(Self.isGated) == true, "\(suite) is not a gated suite any more")
        }
    }
}
