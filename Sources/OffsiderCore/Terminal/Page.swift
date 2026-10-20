import Foundation

/// What a command found, described once: the body goes to stdout and the notices to stderr, each in its reader's words.
public struct Page: Sendable {
    public var blocks: [Block]
    public var notices: [Notice]

    public init(_ blocks: [Block] = [], notices: [Notice] = []) {
        self.blocks = blocks
        self.notices = notices
    }
}

public enum Block: Sendable {
    /// Person: the mark, the bold title, the dim summary right-aligned and a cyan rule. Agent: nothing.
    case header(Header)
    case table(Table)
    /// Person: dim labels padded to one width. Agent: `label: value` lines.
    case fields([Field])
    /// Person: wrapped at the prose width with `` `code` `` cyan. Agent: one line, backticks kept.
    case prose(String)
    /// Person: a green ✅ or red ❌ bold headline with dim details. Agent: plain lines.
    case outcome(Outcome)
    /// Person: cyan commands with dim words beside them. Agent: `  command  about` lines.
    case commands(title: String?, [Shortcut])
    /// Agent stdout as it is, so an existing format stays byte for byte.
    case agent(String)
    /// Blocks only a person sees.
    case person([Block])
}

public struct Header: Sendable {
    public var mark: TerminalStyle.Mark
    /// At most eight words.
    public var title: String
    /// Short parts joined by ` · `, such as `2 running`.
    public var summary: [String]

    public init(_ mark: TerminalStyle.Mark, _ title: String, _ summary: [String] = []) {
        self.mark = mark
        self.title = title
        self.summary = summary
    }
}

public struct Field: Sendable {
    public var label: String
    public var value: Table.Cell

    public init(_ label: String, _ value: Table.Cell) {
        self.label = label
        self.value = value
    }
}

/// A run's end: what happened in one line, then a few details.
public struct Outcome: Sendable {
    public var ok: Bool
    public var headline: String
    public var details: [String]

    public init(ok: Bool, headline: String, details: [String] = []) {
        self.ok = ok
        self.headline = headline
        self.details = details
    }

    public static func done(_ headline: String, details: [String] = []) -> Outcome {
        Outcome(ok: true, headline: headline, details: details)
    }

    public static func failed(_ headline: String, details: [String] = []) -> Outcome {
        Outcome(ok: false, headline: headline, details: details)
    }
}

public struct Shortcut: Sendable {
    public var command: String
    public var about: String

    public init(_ command: String, _ about: String) {
        self.command = command
        self.about = about
    }
}

/// A line on stderr beside the output; build it with untrusted text already quoted by `TerminalText.field`.
public struct Notice: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case warning, note, next
    }

    public var kind: Kind
    /// A person's few words, cause first.
    public var text: String
    /// An agent's full sentence when it differs.
    public var agentText: String?
    public var mark: TerminalStyle.Mark?
    /// Person: a `Try`, `See` or `Next` line. Agent: a `Try:` line, unless the sentence already names it.
    public var command: String?
    /// The word before `command` on a person's line.
    public var label: String

    public init(kind: Kind, text: String, agentText: String? = nil, mark: TerminalStyle.Mark? = nil, command: String? = nil, label: String) {
        self.kind = kind
        self.text = text
        self.agentText = agentText
        self.mark = mark
        self.command = command
        self.label = label
    }

    public static func warning(_ text: String, agent: String? = nil, try command: String? = nil) -> Notice {
        Notice(kind: .warning, text: text, agentText: agent, mark: .warning, command: command, label: "Try")
    }

    public static func note(_ text: String, agent: String? = nil, mark: TerminalStyle.Mark? = nil, see command: String? = nil) -> Notice {
        Notice(kind: .note, text: text, agentText: agent, mark: mark, command: command, label: "See")
    }

    /// The one command a person runs next; agents never see it.
    public static func next(_ command: String) -> Notice {
        Notice(kind: .next, text: "", command: command, label: "Next")
    }
}
