import Foundation
import Testing

/// Every child Offsider starts gets an environment `ChildEnvironment` built: no bare `Process()`, and no spawn handed the caller's whole environment.
@Suite("Child environment lint")
struct ChildEnvironmentLintTests {
    /// The only places a process is created; each takes an environment the call sites below are checked for.
    static let primitives: [String: String] = [
        "OffsiderCore/Process/ProcessCapture.swift": "the one Foundation Process: the Apple tool allow-list, or the caller's, which this lint checks",
        "OffsiderCore/Process/DetachedProcess.swift": "posix_spawn with the caller's environment, which this lint checks",
    ]

    /// Spawn helpers that hand on the environment their own callers built; each caller is a spawn call this lint checks.
    static let forwarders: [String: String] = [
        "OffsiderAndroid/AndroidHost.swift#capture": "each processes.capture call builds its own",
        "OffsiderIOSDevice/Runner/RunnerSession.swift#launch": "RunnerSession builds the xcodebuild profile",
        "OffsiderIOSDevice/Session/DeviceSessionStore.swift#launch": "DeviceSessionClient builds the broker profile",
        "OffsiderIOSDevice/Runner/RunnerBuilder.swift#runXcodebuild": "build makes the xcodebuild profile",
    ]

    static let primitiveCalls = ["Process()", "Process.init(", "Process = .init(", "Process.run(", "NSTask", "posix_spawn(", "posix_spawnp(", "popen(", "execv(", "execve(", "execvp("]
    static let spawnPatterns = ["ProcessCapture.run(", ".launch(", ".capture(", "xcodebuild("]

    struct Offence: Equatable {
        let location: String
        let what: String
    }

    /// The offending lines of `lines`, plus every allow-list key that matched something, so stale entries show.
    static func offences(in lines: [SourceLines.Line]) -> (offences: [Offence], used: Set<String>) {
        var offences: [Offence] = []
        var used: Set<String> = []
        let files = Dictionary(grouping: lines, by: \.file)
        for (file, fileLines) in files {
            let sorted = fileLines.sorted { $0.number < $1.number }
            for (index, line) in sorted.enumerated() where !line.isComment {
                let text = String(line.text)
                if createsProcess(text) {
                    if primitives[file] != nil { used.insert(file) } else { offences.append(Offence(location: line.location, what: "a process created outside ProcessCapture and DetachedProcess")) }
                }
                guard let pattern = spawnPatterns.first(where: { text.contains($0) }), !declares(pattern, in: text) else { continue }
                let call = statement(from: sorted, at: index, pattern: pattern)
                guard pattern == "xcodebuild(" || call.contains("executable:") || call.contains("environment:") else { continue }
                guard let argument = environmentArgument(of: call, positional: pattern == "xcodebuild(") else { continue }
                if argument.contains("ChildEnvironment.make") { continue }
                let scope = enclosingScope(of: sorted, at: index)
                if assigns(argument, fromChildEnvironmentIn: sorted[scope.start...index]) { continue }
                let key = "\(file)#\(scope.name)"
                if forwarders[key] != nil {
                    used.insert(key)
                } else {
                    offences.append(Offence(location: line.location, what: "a child given \(argument), which ChildEnvironment did not build"))
                }
            }
        }
        return (offences.sorted { $0.location < $1.location }, used)
    }

    /// True for a call that makes a process, not one whose name merely ends the same way, such as `DetachedProcess()`.
    static func createsProcess(_ text: String) -> Bool {
        primitiveCalls.contains { call in
            var searchStart = text.startIndex
            while let found = text.range(of: call, range: searchStart..<text.endIndex) {
                if found.lowerBound == text.startIndex { return true }
                let before = text[text.index(before: found.lowerBound)]
                if !(before.isLetter || before.isNumber || before == "_") { return true }
                searchStart = found.upperBound
            }
            return false
        }
    }

    /// True when `pattern` names the function being declared, as `func xcodebuild(` does, rather than a call.
    static func declares(_ pattern: String, in text: String) -> Bool {
        guard let found = text.range(of: pattern) else { return false }
        return text[..<found.lowerBound].hasSuffix("func ")
    }

    /// The call from `pattern` to its closing parenthesis, joined across lines.
    static func statement(from lines: [SourceLines.Line], at index: Int, pattern: String) -> String {
        var text = String(lines[index].text)
        text = String(text[text.range(of: pattern)!.lowerBound...])
        var depth = 0
        var result = ""
        var lineIndex = index
        while true {
            for character in text {
                result.append(character)
                if "([{".contains(character) { depth += 1 }
                if ")]}".contains(character) {
                    depth -= 1
                    if depth == 0 { return result }
                }
            }
            lineIndex += 1
            guard lineIndex < lines.count, lineIndex - index < 12 else { return result }
            text = String(lines[lineIndex].text)
            result.append("\n")
        }
    }

    /// The `environment:` argument, or the second argument of a positional call; nil when there is none.
    static func environmentArgument(of call: String, positional: Bool) -> String? {
        let start: String.Index
        if positional {
            guard let open = call.firstIndex(of: "("), let comma = topLevelEnd(in: call, from: call.index(after: open)), call[comma] == "," else { return nil }
            start = call.index(after: comma)
        } else {
            guard let label = call.range(of: "environment:") else { return nil }
            start = label.upperBound
        }
        guard let end = topLevelEnd(in: call, from: start) else { return nil }
        return call[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `,` or closing bracket that ends the argument starting at `start`.
    static func topLevelEnd(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) {
                if depth == 0 { return index }
                depth -= 1
            }
            if character == ",", depth == 0 { return index }
            index = text.index(after: index)
        }
        return nil
    }

    /// The nearest function or stored closure above `index`, and its name.
    static func enclosingScope(of lines: [SourceLines.Line], at index: Int) -> (start: Int, name: String) {
        let header = #/\bfunc\s+(\w+)|\blet\s+(\w+)\s*(?::[^=]+)?=\s*\{/#
        for candidate in stride(from: index, through: 0, by: -1) {
            if let match = String(lines[candidate].text).firstMatch(of: header) {
                return (candidate, String(match.1 ?? match.2 ?? ""))
            }
        }
        return (0, "")
    }

    /// True when the last whole assignment to `name` in `lines` is a `ChildEnvironment.make` call.
    static func assigns(_ name: String, fromChildEnvironmentIn lines: ArraySlice<SourceLines.Line>) -> Bool {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        let assignment = try! Regex("(?:^|[^A-Za-z0-9_.])\(name)\\s*(?::\\s*\\[String:\\s*String\\])?\\s*=(?!=)")
        let last = lines.last { String($0.text).contains(assignment) }
        return last.map { $0.text.contains("ChildEnvironment.make") } ?? false
    }

    @Test("no child process outside the allow-listed primitives, and none handed an environment ChildEnvironment did not build")
    func sourcesBuildEveryChildEnvironment() throws {
        let lines = try #require(SourceLines.all)
        let (offences, used) = Self.offences(in: lines)
        #expect(offences.isEmpty, "Build these with ChildEnvironment.make: \(offences.map { "\($0.location) (\($0.what))" }.joined(separator: ", "))")
        #expect(Set(Self.primitives.keys).union(Self.forwarders.keys).subtracting(used).isEmpty, "Drop allow-list entries that no longer start a process")
    }

    @Test("the lint flags a bare Process and a spawn handed the caller's environment, and passes one ChildEnvironment built")
    func lintCatchesTheShapesItGuards() {
        func lines(_ text: String) -> [SourceLines.Line] {
            text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { SourceLines.Line(file: "Offsider/Example.swift", number: $0.offset + 1, text: $0.element) }
        }
        let bare = lines("""
            static func kick() async throws {
                let process = Process()
            }
            """)
        #expect(Self.offences(in: bare).offences.map(\.location) == ["Offsider/Example.swift:2"])

        let whole = lines("""
            public func locate() async throws {
                let result = try await ProcessCapture.run(
                    executable: "/usr/bin/xcode-select", arguments: ["-p"], environment: environment, timeout: 5
                )
            }
            public func run() async throws {
                var environment = ChildEnvironment.make(.base, from: environment)
            }
            """)
        #expect(Self.offences(in: whole).offences.map(\.location) == ["Offsider/Example.swift:2"])

        let reassigned = lines("""
            func spawn() async throws {
                var environment = ChildEnvironment.make(.appleTool, from: host)
                environment["DEVELOPER_DIR"] = path
                environment = ProcessInfo.processInfo.environment
                _ = try await ProcessCapture.run(executable: "/bin/sh", arguments: [], environment: environment, timeout: 5)
                let other = Process.init()
            }
            """)
        #expect(Self.offences(in: reassigned).offences.map(\.location) == ["Offsider/Example.swift:5", "Offsider/Example.swift:6"])

        let oneLine = lines("""
            func spawn() async throws { _ = try await ProcessCapture.run(executable: "/bin/sh", arguments: [], environment: ProcessInfo.processInfo.environment, timeout: 5) }
            """)
        #expect(Self.offences(in: oneLine).offences.map(\.location) == ["Offsider/Example.swift:1"])

        let built = lines("""
            func stop() async throws {
                let environment = ChildEnvironment.make(.adbServer, from: host.environment)
                let result = try await host.processes.capture(
                    executable: adb.path, arguments: ["kill"], environment: environment, timeout: 5
                )
                _ = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: ["simctl"], timeout: 5)
            }
            """)
        #expect(Self.offences(in: built).offences.isEmpty)
    }
}
