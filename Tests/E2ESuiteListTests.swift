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

    /// `@Suite` declarations in the test sources, with whether an E2E flag gates each one.
    private static func suites() throws -> [String: Bool] {
        let files = try #require(FileManager.default.enumerator(at: testsFolder, includingPropertiesForKeys: nil))
        let declaration = #/@Suite\((.*?)\)\s*(?:@\w+\s+)*(?:(?:final|private|fileprivate|public)\s+)*(?:struct|class|enum|actor)\s+(\w+)/#.dotMatchesNewlines()
        var found: [String: Bool] = [:]
        for case let file as URL in files where file.pathExtension == "swift" {
            for match in try String(contentsOf: file, encoding: .utf8).matches(of: declaration) {
                found[String(match.2)] = match.1.contains(#/\bis\w*E2EEnabled\b|RNPlatform\.anyEnabled/#)
            }
        }
        return found
    }

    /// Every suite `test-runner.sh` names on its own in quotes: its lists and the modes that run one suite.
    private static func listed() throws -> Set<String> {
        let runner = testsFolder.deletingLastPathComponent().appendingPathComponent("test-runner.sh")
        let source = try String(contentsOf: runner, encoding: .utf8)
        return Set(source.matches(of: #/"([A-Z]\w*Tests)"/#).map { String($0.1) })
    }

    @Test("every suite gated on an E2E flag is in a run list of test-runner.sh")
    func gatedSuitesAreListed() throws {
        let suites = try Self.suites()
        let gated = Set(suites.filter(\.value).keys)
        #expect(gated.isSuperset(of: ["TapTests", "AndroidTapTests", "ReactNativeRowsTests", "FoldableTests", "IOSDeviceInputE2ETests"]), "the @Suite scan found too little")
        let missing = gated.subtracting(try Self.listed()).subtracting(Self.runAnotherWay)
        #expect(missing.isEmpty, "add these to a list in test-runner.sh, or to runAnotherWay with how they run: \(missing.sorted())")
    }

    @Test("every suite a list names exists, since a name that matches nothing passes")
    func listedSuitesExist() throws {
        let unknown = try Self.listed().subtracting(try Self.suites().keys)
        #expect(unknown.isEmpty, "test-runner.sh names suites that do not exist: \(unknown.sorted())")
    }

    @Test("a suite run another way is still gated, so the exception cannot go stale")
    func exceptionsAreGated() throws {
        let suites = try Self.suites()
        for suite in Self.runAnotherWay {
            #expect(suites[suite] == true, "\(suite) is not a gated suite any more")
        }
    }
}
