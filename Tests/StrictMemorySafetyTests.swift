import Foundation
import Testing

@Suite("Strict memory safety")
struct StrictMemorySafetyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func targetBlock(_ name: String, in manifest: String) -> Substring? {
        guard let start = manifest.range(of: #"\.target\(\s*name: ""# + name + #"","#, options: .regularExpression) else { return nil }
        let rest = manifest[start.upperBound...]
        let end = rest.range(of: "\n        ),")?.lowerBound ?? rest.endIndex
        return rest[..<end]
    }

    @Test("Every library target that touches raw memory builds with strict memory safety", arguments: ["OffsiderCore", "OffsiderAndroid", "OffsiderIOSDevice"])
    func libraryTargetsAreStrict(target: String) throws {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let block = try #require(Self.targetBlock(target, in: manifest))
        #expect(block.contains(".strictMemorySafety()"))
    }
}
