import Foundation

/// `audit.file` and `audit.chain`: whether the physical-device audit trail is a private file whose lines still link.
public enum AuditDoctorRules {
    public static let tightenCommand = "chmod 600 ~/.config/offsider/device-audit.log"
    public static let personHint = "Ask the user to look at ~/.config/offsider/device-audit.log: Offsider never replaces or removes it."

    public static func checks(file: AuditTrail.FileState, chain: AuditTrail.Chain) -> [DoctorCheckResult] {
        [DoctorCheckResult(id: .auditFile, verdict: self.file(file)), DoctorCheckResult(id: .auditChain, verdict: self.chain(chain))]
    }

    public static func file(_ state: AuditTrail.FileState) -> DoctorRules.Verdict {
        switch state {
        case .none: return (.pass, "No physical device has been driven or refused, so there is no audit trail yet", nil)
        case .safe(let bytes): return (.pass, "device-audit.log is private to this user (\(bytes / 1024) KB)", nil)
        case .readableByOthers: return (.warn, "device-audit.log can be read by other users of this Mac; the next record written makes it private again", tightenCommand)
        case .unusable(let detail):
            return (.warn, "\(TerminalText.line(detail, cap: 300, keepsTab: false)), so physical-device commands are recorded only in the unified log", personHint)
        }
    }

    public static func chain(_ chain: AuditTrail.Chain) -> DoctorRules.Verdict {
        switch chain {
        case .none: return (.pass, "No records to check", nil)
        case .intact(let lines): return (.pass, "\(lines) record\(lines == 1 ? "" : "s"), each linked to the one before", nil)
        case .broken(let file, let line):
            return (.warn, "\(file) line \(line) does not follow the line before it: the trail was edited or cut", "Compare it with the unified log: `log show --predicate '\(AuditTrail.logPredicate)'`.")
        case .unreadable(let detail): return (.warn, "The audit trail could not be read (\(TerminalText.line(detail, cap: 300, keepsTab: false)))", personHint)
        }
    }
}
