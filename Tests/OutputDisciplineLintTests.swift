import Foundation
import Testing

/// Commands write through `Console`; each file's remaining raw writes are budgeted, and a budget only shrinks.
@Suite("Output discipline lint")
struct OutputDisciplineLintTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    static let patterns = [#"(^|[^\w.])print\("#, #"FileHandle\.standard(Output|Error)\.write"#, #"&standardError"#, #"fputs\("#]

    /// Raw writes each file may still make.
    static let budgets: [String: Int] = [
        "AndroidSession.swift": 1,
        "Appearance.swift": 1,
        "Batch.swift": 1,
        "Biometric.swift": 2,
        "Boot.swift": 11,
        "Button.swift": 2,
        "ContentSize.swift": 2,
        "Credential.swift": 6,
        "DescribeUI.swift": 3,
        "DeviceAccess.swift": 4,
        "DeviceSession.swift": 2,
        "Displays.swift": 1,
        "Doctor.swift": 3,
        "Guide.swift": 2,
        "Init.swift": 3,
        "Lease.swift": 2,
        "Login.swift": 3,
        "Logs.swift": 5,
        "Orientation.swift": 3,
        "Permission.swift": 2,
        "Posture.swift": 1,
        "RN.swift": 1,
        "RNDevMenu.swift": 5,
        "RNLogBox.swift": 8,
        "RNOpen.swift": 4,
        "RecordVideo.swift": 7,
        "Run.swift": 17,
        "Runner.swift": 7,
        "Screenshot.swift": 5,
        "Session.swift": 5,
        "Shake.swift": 1,
        "Slider.swift": 1,
        "StatusBar.swift": 2,
        "StayAwake.swift": 2,
        "StreamVideo.swift": 13,
        "Tap.swift": 5,
        "Turnstile.swift": 4,
        "Type.swift": 2,
        "UnlockCode.swift": 3,
        "VideoMasking.swift": 2,
        "Wait.swift": 6,
        "Wake.swift": 1,
    ]

    static func code(_ url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    static func counts() throws -> [String: Int] {
        let commands = Self.sources.appendingPathComponent("Offsider/Commands")
        let files = try FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            + [Self.sources.appendingPathComponent("Offsider/main.swift")]
        let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
        var counts: [String: Int] = [:]
        for file in files {
            let count = try code(file).reduce(0) { total, line in
                total + expressions.reduce(0) { $0 + $1.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) }
            }
            if count > 0 { counts[file.lastPathComponent] = count }
        }
        return counts
    }

    @Test("no command writes raw output beyond its budget; new output goes through Console")
    func withinBudget() throws {
        for (file, count) in try Self.counts().sorted(by: { $0.key < $1.key }) {
            let budget = Self.budgets[file] ?? 0
            #expect(count <= budget, "\(file) makes \(count) raw writes, over its budget of \(budget): use Console.current")
        }
    }

    @Test("no budget is larger than the file needs", .disabled("until every command is converted"))
    func noStaleBudgets() throws {
        let counts = try Self.counts()
        for (file, budget) in Self.budgets {
            #expect(counts[file, default: 0] == budget, "lower \(file)'s budget to \(counts[file, default: 0])")
        }
    }

    @Test("only the prompt and the presence check open /dev/tty")
    func devTTY() throws {
        let allowed: Set = ["Offsider/Utilities/TerminalPrompt.swift", "Offsider/Utilities/PersonPresence.swift"]
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.sources.path.count + 1))
            if try Self.code(url).contains(where: { $0.contains("\"/dev/tty\"") }), !allowed.contains(relative) { offenders.append(relative) }
        }
        #expect(offenders.isEmpty, "Write through Console instead: \(offenders.joined(separator: ", "))")
    }
}
