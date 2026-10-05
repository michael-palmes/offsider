import Foundation

/// One `manifest.ndjson` line: a `screenshot` or `logs` invocation, or a batch screenshot step, failures included.
public struct RunManifestLine: Codable, Equatable, Sendable {
    /// The file's number; nil when the command wrote no file.
    public var n: Int?
    public var file: String?
    public var command: String
    public var step: Int?
    /// The batch step line, already redacted.
    public var line: String?
    public var device: String?
    public var platform: String?
    public var time: Date
    public var ms: Int
    public var exit: Int
    public var reason: String?
    /// The command's arguments after its name, each passed through `LogRedactor`.
    public var args: [String]?
    /// The `--output` copy, when one was written too.
    public var output: String?
    public var diff: String?
    public var masked: Int?
    public var changed: Bool?
    public var entries: Int?
    public var redacted: Int?

    public init(
        n: Int? = nil, file: String? = nil, command: String, step: Int? = nil, line: String? = nil, device: String? = nil, platform: String? = nil,
        time: Date, ms: Int, exit: Int, reason: String? = nil, args: [String]? = nil, output: String? = nil, diff: String? = nil,
        masked: Int? = nil, changed: Bool? = nil, entries: Int? = nil, redacted: Int? = nil
    ) {
        self.n = n
        self.file = file
        self.command = command
        self.step = step
        self.line = line
        self.device = device
        self.platform = platform
        self.time = time
        self.ms = ms
        self.exit = exit
        self.reason = reason
        self.args = args
        self.output = output
        self.diff = diff
        self.masked = masked
        self.changed = changed
        self.entries = entries
        self.redacted = redacted
    }

    public func jsonLine(timeZone: TimeZone = .current) -> String {
        json(timeZone: timeZone).rendered(compact: true)
    }

    func json(timeZone: TimeZone = .current) -> OrderedJSON {
        .object([
            ("n", .optional(n, OrderedJSON.integer)),
            ("file", .optional(file, OrderedJSON.string)),
            ("command", .string(command)),
            ("step", .optional(step, OrderedJSON.integer)),
            ("line", .optional(line, OrderedJSON.string)),
            ("device", .optional(device, OrderedJSON.string)),
            ("platform", .optional(platform, OrderedJSON.string)),
            ("time", .string(RunClock.iso(time, timeZone: timeZone))),
            ("ms", .integer(ms)),
            ("exit", .integer(exit)),
            ("reason", .optional(reason, OrderedJSON.string)),
            ("args", .optional(args) { .array($0.map(OrderedJSON.string)) }),
            ("output", .optional(output, OrderedJSON.string)),
            ("diff", .optional(diff, OrderedJSON.string)),
            ("masked", .optional(masked, OrderedJSON.integer)),
            ("changed", .optional(changed, OrderedJSON.bool)),
            ("entries", .optional(entries, OrderedJSON.integer)),
            ("redacted", .optional(redacted, OrderedJSON.integer)),
        ])
    }

    public init(jsonLine: String) throws {
        self = try RunCoding.decoder.decode(RunManifestLine.self, from: Data(jsonLine.utf8))
    }
}
