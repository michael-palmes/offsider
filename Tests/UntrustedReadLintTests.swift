import Foundation
import Testing

/// Whole-file reads in `Sources/` go through `UntrustedRead` (or `readOwnedFile` for private files), so a FIFO or a symlink to a device cannot hang or exhaust a command.
@Suite("Untrusted read lint")
struct UntrustedReadLintTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    static let patterns = ["FileManager.default.contents(atPath", "Data(contentsOf:", "String(contentsOf"]

    /// Sites that read a file Offsider or a trusted tool just wrote in a folder only this user can write, or a bundle Apple signed; each says why.
    static let allowed: [String: String] = [
        // Hashes the runner build products xcodebuild wrote into Offsider's private runner cache.
        "OffsiderIOSDevice/Runner/RunnerBuilder.swift": "private runner build products",
        // Reads the runner's Info.plist and products from the same private build folder.
        "OffsiderIOSDevice/Runner/RunnerProducts.swift": "private runner build products",
        // The PNG devicectl wrote to a temporary path Offsider created for it.
        "OffsiderIOSDevice/Screen/IOSDeviceScreenshot.swift": "devicectl output in Offsider's temporary file",
        // simctl output into temporary files Offsider created.
        "Offsider/Utilities/SimctlScreenshot.swift": "simctl output in Offsider's temporary file",
        "Offsider/Platform/IOS/IOSDisplayCatalog.swift": "simctl output and the selected Xcode's device type profile",
        // The agent skill files `init` installs and compares.
        "Offsider/Commands/Init.swift": "the skill files init installs",
        // The reader itself.
        "OffsiderCore/Process/UntrustedRead.swift": "the helper",
    ]

    @Test("no unguarded whole-file read outside UntrustedRead and the reviewed sites")
    func noUnguardedReads() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var seen: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.sources.path.count + 1))
            let text = try String(decoding: Data(contentsOf: url), as: UTF8.self)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.patterns.contains(where: line.contains) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if Self.allowed[relative] != nil {
                    seen.insert(relative)
                } else {
                    offenders.append("\(relative):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "Read these through UntrustedRead: \(offenders.joined(separator: ", "))")
        #expect(Set(Self.allowed.keys).subtracting(seen).subtracting(["OffsiderCore/Process/UntrustedRead.swift"]).isEmpty, "Drop allow-list entries that no longer read files")
    }
}
