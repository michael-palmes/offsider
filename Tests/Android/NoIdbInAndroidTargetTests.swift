import Foundation
import Testing

@Suite("OffsiderAndroid never links idb")
struct NoIdbInAndroidTargetTests {
    private static let sourcesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/OffsiderAndroid", isDirectory: true)

    private static let forbiddenImport = try! NSRegularExpression(
        pattern: #"^\s*(@\w+\s+)*import\s+(\w+\s+)?(FB\w*|XCTestBootstrap|Offsider)(\.\w+)?\s*$"#,
        options: [.anchorsMatchLines]
    )

    @Test("no Android source imports FB frameworks, XCTestBootstrap or the executable")
    func noForbiddenImports() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil))
        let swiftFiles = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!swiftFiles.isEmpty)

        var offenders: [String] = []
        for file in swiftFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in Self.forbiddenImport.matches(in: text, range: range) {
                offenders.append("\(file.lastPathComponent): \((text as NSString).substring(with: match.range).trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("the import check catches the imports it exists to stop", arguments: [
        "import FBSimulatorControl", "@preconcurrency import FBControlCore", "import XCTestBootstrap", "@testable import Offsider",
    ])
    func patternCatchesForbiddenImports(line: String) {
        let text = "import Foundation\n\(line)\n"
        #expect(Self.forbiddenImport.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 1)
    }

    @Test("OffsiderCore stays allowed")
    func coreImportIsAllowed() {
        let text = "import OffsiderCore\n"
        #expect(Self.forbiddenImport.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 0)
    }
}
