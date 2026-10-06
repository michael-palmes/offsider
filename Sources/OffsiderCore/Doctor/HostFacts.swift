import Foundation

/// Another running Offsider command: only its subcommand and device, never its other arguments or environment.
public struct HostSession: Codable, Equatable, Sendable {
    public let pid: Int32
    public let command: String?
    public let device: String?
    public let startedAt: Date?

    public init(pid: Int32, command: String?, device: String?, startedAt: Date?) {
        self.pid = pid
        self.command = command
        self.device = device
        self.startedAt = startedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(command, forKey: .command)
        try container.encode(device, forKey: .device)
        try container.encode(startedAt.map(ProcessStamp.timestamp), forKey: .startedAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        device = try container.decodeIfPresent(String.self, forKey: .device)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case pid, command, device, startedAt
    }
}

/// What a busy Mac looks like to `doctor`: load, CPUs, memory, free disk and other Offsider commands.
public struct HostFacts: Codable, Equatable, Sendable {
    /// 1, 5 and 15 minutes; empty when unreadable.
    public let loadAverage: [Double]
    public let cpuCount: Int?
    public let memoryGB: Double?
    public let diskFreeGB: Double?
    public let diskPath: String
    public let sessions: [HostSession]

    public init(loadAverage: [Double], cpuCount: Int?, memoryGB: Double?, diskFreeGB: Double?, diskPath: String, sessions: [HostSession]) {
        self.loadAverage = loadAverage
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.diskFreeGB = diskFreeGB
        self.diskPath = diskPath
        self.sessions = sessions
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(loadAverage, forKey: .loadAverage)
        try container.encode(cpuCount, forKey: .cpuCount)
        try container.encode(memoryGB, forKey: .memoryGB)
        try container.encode(diskFreeGB, forKey: .diskFreeGB)
        try container.encode(diskPath, forKey: .diskPath)
        try container.encode(sessions, forKey: .sessions)
    }

    /// `load 3.2 on 10 CPUs, 64 GB RAM, 120 GB free on /Users/me, 2 other Offsider commands`.
    public var summary: String {
        var parts: [String] = []
        if let load = loadAverage.first {
            parts.append(String(format: "load %.1f", load) + (cpuCount.map { " on \($0) CPUs" } ?? ""))
        }
        if let memoryGB { parts.append(String(format: "%.0f GB RAM", memoryGB)) }
        if let diskFreeGB { parts.append(String(format: "%.0f GB free on %@", diskFreeGB, diskPath)) }
        parts.append(sessions.count == 1 ? "1 other Offsider command" : "\(sessions.count) other Offsider commands")
        return parts.joined(separator: ", ")
    }
}

/// Reads another Offsider process's `KERN_PROCARGS2` buffer, keeping only its subcommand and device: typed text never leaves it.
public enum HostSessionParser {
    /// Commands whose first argument is a subcommand of their own.
    static let groups: Set<String> = ["rn", "runner", "session", "device-session"]

    /// `isCommand` names Offsider's top-level commands, so a stray argument is never taken for one.
    public static func parse(_ buffer: [UInt8], isCommand: (String) -> Bool) -> (command: String?, device: String?) {
        guard buffer.count > 4 else { return (nil, nil) }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var strings: [String] = []
        var index = 4
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        while index < buffer.count, strings.count < argc + 256 {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        guard argc >= 1, strings.count >= argc else { return (nil, nil) }
        let arguments = Array(strings[1..<argc])
        let environment = strings[argc...]

        var command: String?
        if let first = arguments.first, isCommand(first) {
            command = first
            if groups.contains(first), arguments.count > 1, isSubcommandWord(arguments[1]) {
                command = "\(first) \(arguments[1])"
            }
        }
        var device: String?
        for (offset, argument) in arguments.enumerated() {
            if argument == "--device", offset + 1 < arguments.count {
                device = arguments[offset + 1]
                break
            }
            if argument.hasPrefix("--device=") {
                device = String(argument.dropFirst("--device=".count))
                break
            }
            if argument == "--" { break }
        }
        if device == nil {
            device = environment.first { $0.hasPrefix("OFFSIDER_DEVICE=") }.map { String($0.dropFirst("OFFSIDER_DEVICE=".count)) }
        }
        return (command, device.flatMap(deviceID))
    }

    private static func isSubcommandWord(_ text: String) -> Bool {
        (1...24).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "-") }
    }

    /// Device IDs are letters, digits, `.`, `_`, `-` and `:`; anything else is dropped.
    private static func deviceID(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(trimmed.count), trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-:".contains($0)) }) else { return nil }
        return trimmed
    }
}

/// `host.load`, `host.disk` and `host.sessions`, on every doctor report.
public enum HostDoctorRules {
    public static let loadPerCPU = 4.0
    public static let diskWarnGB = 10.0
    public static let diskFailGB = 2.0

    public static func checks(_ facts: HostFacts) -> [DoctorCheckResult] {
        [
            DoctorCheckResult(id: .hostLoad, verdict: load(facts)),
            DoctorCheckResult(id: .hostDisk, verdict: disk(facts)),
            DoctorCheckResult(id: .hostSessions, verdict: sessions(facts.sessions)),
        ]
    }

    public static func load(_ facts: HostFacts) -> DoctorRules.Verdict {
        guard let load = facts.loadAverage.first, let cpus = facts.cpuCount, cpus > 0 else { return (.skip, "could not read the load average", nil) }
        let detail = String(format: "%.1f over the last minute on %d CPUs", load, cpus)
        guard load > loadPerCPU * Double(cpus) else { return (.pass, detail, nil) }
        return (
            .warn,
            detail + "; commands, boots and screen reads run slower and may time out",
            "Close other emulators, builds or agents, or give commands longer timeouts."
        )
    }

    public static func disk(_ facts: HostFacts) -> DoctorRules.Verdict {
        guard let free = facts.diskFreeGB else { return (.skip, "could not read the free space on \(facts.diskPath)", nil) }
        let detail = String(format: "%.1f GB free on %@", free, facts.diskPath)
        let hint = "Free space: emulator snapshots, simulators and builds fail when the disk fills."
        if free < diskFailGB { return (.fail, detail, hint) }
        if free < diskWarnGB { return (.warn, detail, hint) }
        return (.pass, detail, nil)
    }

    public static func sessions(_ sessions: [HostSession]) -> DoctorRules.Verdict {
        guard !sessions.isEmpty else { return (.pass, "No other Offsider commands are running", nil) }
        let list = sessions.map { session in
            "pid \(session.pid) " + (session.command ?? "offsider") + (session.device.map { " on \($0)" } ?? "")
        }
        return (.pass, "\(sessions.count) other Offsider command\(sessions.count == 1 ? "" : "s"): " + list.joined(separator: ", "), nil)
    }
}
