import Foundation
import Testing

/// Every crash on a simulator raises a "quit unexpectedly" dialog on the Mac, so no test or fixture crashes an app or a system process on purpose.
@Suite("No deliberate crash")
struct NoDeliberateCrashTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Traps, crash signals, `am crash`, killed system processes and crash buttons; SIGINT, SIGTERM and SIGKILL write no report, so they pass.
    static let patterns: [(name: String, regex: String)] = [
        ("a trap", #"\b(fatalError|preconditionFailure|assertionFailure|__builtin_trap)\(|\babort\(\)|\bNSException\b.*\braise\b"#),
        ("a crash signal", #"\b(raise|kill)\(.*\bSIG(SEGV|ABRT|BUS|ILL|TRAP|FPE|SYS|QUIT|EMT)\b|\b(p?kill|killall)\s+(-s\s+|-)(SIG)?(SEGV|ABRT|BUS|ILL|TRAP|FPE|SYS|QUIT|EMT|3|4|5|6|7|8|10|11|12)\b"#),
        ("am crash", #"\bam\s+crash\b"#),
        ("a system process killed", #"\b(killall|pkill)\b.*\b(SpringBoard|PosterBoard|backboardd|system_server)\b|\blaunchctl\s+kill\b"#),
        ("a crash button", #"crash-now|\b(crashNow|forceCrash|nativeCrash)\b|\.crash\(\)"#),
    ]

    /// Tests, the playground apps, the runner and the scripts; this file names the patterns, so it is left out.
    private static func scannedFiles() throws -> [URL] {
        let folders: [(String, Set<String>)] = [
            ("Tests", ["swift", "sh"]),
            ("OffsiderPlaygroundApp", ["swift"]),
            ("OffsiderPlaygroundRN/src", ["ts", "tsx"]),
            ("scripts", ["sh"]),
        ]
        var files = [root.appendingPathComponent("test-runner.sh"), root.appendingPathComponent("OffsiderPlaygroundRN/App.tsx")]
        for (folder, extensions) in folders {
            let enumerator = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where extensions.contains(file.pathExtension) && file.lastPathComponent != "NoDeliberateCrashTests.swift" {
                files.append(file)
            }
        }
        return files
    }

    private static func compiled() throws -> [(name: String, regex: NSRegularExpression)] {
        try patterns.map { ($0.name, try NSRegularExpression(pattern: $0.regex)) }
    }

    /// The names of the patterns `text` matches, with the line each match starts on.
    static func matches(_ text: String, _ regexes: [(name: String, regex: NSRegularExpression)]) -> [(line: Int, name: String)] {
        let whole = NSRange(text.startIndex..., in: text)
        return regexes.flatMap { pattern in
            pattern.regex.matches(in: text, range: whole).map { match in
                let before = (text as NSString).substring(to: match.range.location)
                return (before.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }, pattern.name)
            }
        }
    }

    @Test("the patterns catch a crash and pass a clean stop", arguments: [
        ("fatalError(\"Crash test\")", true),
        ("_ = try await CommandRunner.runSeparated(\"/bin/kill -SEGV \\(pid)\")", true),
        ("kill -11 4100", true),
        ("try await AndroidE2E.shell(\"am crash \\(package)\")", true),
        ("xcrun simctl spawn booted killall -9 SpringBoard", true),
        (".accessibilityIdentifier(\"crash-now\")", true),
        ("_ = try await CommandRunner.runSeparated(\"/bin/kill -TERM \\(pid)\")", false),
        ("try await AndroidE2E.shell(\"am force-stop \\(package)\")", false),
        ("su 0 kill -STOP 4100", false),
        ("DispatchQueue.global().async { kill(getpid(), SIGINT) }", false),
        ("raise(SIGABRT)", true),
        ("xcrun simctl spawn booted killall -SEGV OffsiderPlayground", true),
        ("pkill -ABRT -f OffsiderPlayground", true),
        ("__builtin_trap()", true),
        ("NSException(name: .genericException, reason: nil).raise()", true),
        ("flag.raise()", false),
        ("exit(0)", false),
        ("11-04 08:00:02.500 F libc: Fatal signal 11 (SIGSEGV), code 1", false),
    ])
    func patternsCatchCrashes(line: String, crashes: Bool) throws {
        #expect(!Self.matches(line, try Self.compiled()).isEmpty == crashes, "\(line)")
    }

    @Test("no test, fixture or script crashes an app or a system process on purpose")
    func noDeliberateCrash() throws {
        let files = try Self.scannedFiles()
        let regexes = try Self.compiled()
        #expect(files.count > 100, "the scan found only \(files.count) files")
        var found: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            let path = file.path.replacingOccurrences(of: Self.root.path + "/", with: "")
            for (number, name) in Self.matches(source, regexes) {
                found.append("\(path):\(number) (\(name)): \(lines[number - 1].trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(found.isEmpty, "End the app cleanly instead (the playground's quit-now, kill -TERM, am force-stop); test crash detection with a made-up report in Tests/Fixtures/crash-reports:\n\(found.joined(separator: "\n"))")
    }
}
