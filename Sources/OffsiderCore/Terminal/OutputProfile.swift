import Darwin
import Foundation

/// Who reads standard output: a person at a terminal, or a program such as an agent harness.
/// `.agent` quotes every untrusted field, refuses `--no-mask-secure` without a person and hides `--raw-source`.
public enum OutputProfile: String, Sendable, CaseIterable {
    case person
    case agent

    /// `OFFSIDER_OUTPUT=person|agent` overrides the terminal check, for tests and scripts.
    public static let variable = "OFFSIDER_OUTPUT"

    /// Tests inject a profile; nil uses the one this process detected.
    @TaskLocal public static var override: OutputProfile?

    /// The profile for this process: the override, else `OFFSIDER_OUTPUT`, else an agent's marker, else whether standard output is a terminal.
    public static var current: OutputProfile { override ?? detected }

    /// One `isatty` per process.
    public static let detected: OutputProfile = resolve(
        environment: ProcessInfo.processInfo.environment, isTerminal: isatty(STDOUT_FILENO) != 0
    )

    /// `OFFSIDER_OUTPUT` when it names a profile; an unknown value is ignored, so a typo never loosens the agent profile.
    public static func named(in environment: [String: String]) -> OutputProfile? {
        environment[variable].flatMap { OutputProfile(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    /// Markers only ever move the answer towards `.agent`, so an agent on a pseudo-terminal still gets the agent's gates.
    public static func resolve(environment: [String: String], isTerminal: Bool) -> OutputProfile {
        if let named = named(in: environment) { return named }
        if AgentMarkers.present(in: environment) { return .agent }
        return isTerminal ? .person : .agent
    }
}

/// The variables an agent harness sets in the commands it runs. Never `CLAUDECODE`: IDE extensions set it in terminals people use.
public enum AgentMarkers {
    public static let variables = ["CLAUDE_CODE_CHILD_SESSION", "AI_AGENT"]

    /// True when any marker is set to something other than empty or `0`.
    public static func present(in environment: [String: String]) -> Bool {
        variables.contains { name in
            environment[name].map { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && trimmed != "0"
            } ?? false
        }
    }
}

/// The top-level `"untrusted"` list a JSON document carries: the paths whose values came from a device or an app.
/// Paths are compact: `devices[].name` is every element's `name`, `details` a top-level key.
public enum UntrustedPaths {
    public static let key = "untrusted"

    /// `json` (one object, pretty or compact) with `"untrusted": [paths]` added after every other key; unchanged when `paths` is empty.
    public static func appending(_ paths: [String], to json: String) -> String {
        guard !paths.isEmpty else { return json }
        var body = Substring(json)
        var trailing = ""
        while let last = body.last, last.isWhitespace {
            trailing = String(last) + trailing
            body = body.dropLast()
        }
        guard body.last == "}" else { return json }
        body = body.dropLast()
        let pretty = body.contains("\n")
        var inner = body
        while let last = inner.last, last.isWhitespace { inner = inner.dropLast() }
        let empty = inner.last == "{"
        var list = ""
        OrderedJSON.array(paths.map(OrderedJSON.string)).writeInline(to: &list, pretty: pretty)
        var keyText = ""
        OrderedJSON.writeString(key, to: &keyText)
        if pretty {
            let closingIndent = String(body.reversed().prefix { $0 == " " })
            let colon = inner.contains("\" : ") ? " : " : ": "
            return String(inner) + (empty ? "\n" : ",\n") + closingIndent + "  " + keyText + colon + list + "\n" + closingIndent + "}" + trailing
        }
        return String(inner) + (empty ? "" : ",") + keyText + ":" + list + "}" + trailing
    }
}

extension OrderedJSON {
    /// An array of strings on one line, `["a", "b"]` when `pretty`, `["a","b"]` otherwise.
    func writeInline(to output: inout String, pretty: Bool) {
        guard case .array(let elements) = self else {
            output += rendered(compact: true)
            return
        }
        output += "["
        for (index, element) in elements.enumerated() {
            if index > 0 { output += pretty ? ", " : "," }
            output += element.rendered(compact: true)
        }
        output += "]"
    }
}

extension UntrustedPaths {
    /// A tree node's keys whose text the app wrote.
    static let nodeFields = [
        "id", "label", "value",
        "native.title", "native.help", "native.customActions", "native.roleDescription",
        "native.text", "native.contentDescription", "native.hint", "native.stateDescription", "native.testTag",
    ]

    /// A near match's or candidate's keys whose text the app wrote.
    static let candidateFields = ["id", "label", "window", "screen"]

    /// The `error` object's keys whose text came from a device, an app or a saved note.
    static let errorFields = ["message"]
        + under("candidates[]", candidateFields)
        + under("coveredBy", ["id", "label", "screen", "process"])
        + under("users[]", ["tags", "about"])

    /// `fields` under `prefix`: `under("error", ["message"])` is `["error.message"]`.
    static func under(_ prefix: String, _ fields: [String]) -> [String] {
        fields.map { prefix + "." + $0 }
    }

    /// The candidates that name at least one value that is not null, an empty string or an empty array.
    /// `a.b` is a key path, `a[]` every element of an array, and `a[]**` the object itself and every element at any depth under `a`.
    static func present(_ candidates: [String], in document: OrderedJSON) -> [String] {
        var resolved: [Substring: [OrderedJSON]] = [:]
        func values(_ path: Substring) -> [OrderedJSON] {
            if path.isEmpty { return [document] }
            if let known = resolved[path] { return known }
            let split = path.lastIndex(of: ".")
            let parent = values(split.map { path[..<$0] } ?? "")
            var segment = split.map { path[path.index(after: $0)...] } ?? path
            var result: [OrderedJSON]
            if segment.hasSuffix("[]**") {
                segment = segment.dropLast(4)
                result = []
                var pending = parent
                while let next = pending.popLast() {
                    result.append(next)
                    pending += next.member(segment)?.elements ?? []
                }
            } else if segment.hasSuffix("[]") {
                segment = segment.dropLast(2)
                result = parent.flatMap { $0.member(segment)?.elements ?? [] }
            } else {
                result = parent.compactMap { $0.member(segment) }
            }
            resolved[path] = result
            return result
        }
        return candidates.filter { candidate in values(Substring(candidate)).contains(where: \.carriesText) }
    }

    /// `document` with `"untrusted"` last, naming the candidates it holds; unchanged when it holds none.
    static func marked(_ document: OrderedJSON, _ candidates: [String]) -> OrderedJSON {
        guard case .object(let members) = document else { return document }
        let paths = present(candidates, in: document)
        guard !paths.isEmpty else { return document }
        return .object(members + [(key, .array(paths.map(OrderedJSON.string)))])
    }
}

extension OrderedJSON {
    func member(_ name: Substring) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.0 == name }?.1
    }

    var elements: [OrderedJSON] {
        guard case .array(let elements) = self else { return [] }
        return elements
    }

    var carriesText: Bool {
        switch self {
        case .null: return false
        case .string(let text): return !text.isEmpty
        case .array(let elements): return !elements.isEmpty
        default: return true
        }
    }
}
