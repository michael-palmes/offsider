import Darwin
import Foundation
import OffsiderCore

extension AuditTrail {
    /// The trail this process writes: the file beside the allow-list and the unified log, stamped with this build, command and calling session.
    static let live = AuditTrail(
        directory: UserConfigDirectory.live(),
        stamp: {
            let session = ProcessAncestry.owner(from: getppid(), in: .live).map { AuditRecord.Session(pid: $0.pid, name: $0.name) }
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

    /// Only a path from the command tree is recorded; a word that failed to parse never is.
    static func command(_ name: String?) -> String? {
        name.flatMap { CommandEffect.table[$0] == nil ? nil : $0 }
    }
}
