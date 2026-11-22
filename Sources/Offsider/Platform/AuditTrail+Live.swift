import Darwin
import Foundation
import OffsiderCore

extension AuditTrail {
    /// The trail this process writes: the file beside the allow-list and the unified log, stamped with this build, command and calling session.
    static let live = AuditTrail(
        directory: UserConfigDirectory.live(),
        stamp: {
            let session = AuditTrail.session(from: getppid())
            let started = ProcessStartTime.date(of: getpid())
            return Stamp(
                version: VERSION, pid: getpid(), session: session, command: command(ErrorReporter.context.command),
                milliseconds: started.map { Int(Date().timeIntervalSince($0) * 1000) }
            )
        },
        mirror: AuditTrail.unifiedLog,
        managed: { ManagedDevicePolicy.read(from: LiveManagedPreferences()).present },
        problem: { detail in
            Console.current.data("Note: Offsider could not write its audit trail (\(TerminalText.line(detail, cap: 300, keepsTab: false))). Run `offsider doctor`.\n", to: .err)
        }
    )

    /// The first ancestor that is not a shell or wrapper, as a lease records its owner, stopping there instead of walking on to launchd.
    static func session(from parent: Int32, in table: ProcessTable = .quick) -> AuditRecord.Session? {
        var current = parent
        for _ in 0..<ProcessAncestry.maximumDepth {
            guard current > 1, let entry = table.lookup(current) else { return nil }
            if !ProcessAncestry.wrappers.contains(entry.identity.name) { return AuditRecord.Session(pid: entry.identity.pid, name: entry.identity.name) }
            guard entry.parent != current else { return nil }
            current = entry.parent
        }
        return nil
    }

    /// Only a path from the command tree is recorded; a word that failed to parse never is.
    static func command(_ name: String?) -> String? {
        name.flatMap { CommandEffect.table[$0] == nil ? nil : $0 }
    }
}

extension ProcessTable {
    /// `proc_pidinfo`, several times quicker than `sysctl` for the user's own processes; another user's, such as a terminal's `login`, falls back to `live`.
    static let quick = ProcessTable { pid in
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return ProcessTable.live.lookup(pid) }
        // `pbi_comm` drops the sixteenth character `sysctl` keeps, so the longer name is cut to match.
        let long = unsafe withUnsafeBytes(of: info.pbi_name) { unsafe String(decoding: $0.prefix { $0 != 0 }.prefix(16), as: UTF8.self) }
        let name = long.isEmpty ? unsafe withUnsafeBytes(of: info.pbi_comm) { unsafe String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : long
        let identity = ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, name: name)
        return (identity, Int32(info.pbi_ppid))
    }
}
