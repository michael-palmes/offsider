import Foundation

/// `device.lease`, on every device report: an advisory lease another session holds is a warning, never a failure.
public enum DeviceLeaseRules {
    public static let sessionVariable = "OFFSIDER_LEASE"

    /// Whose a lease is, seen from the command reading it.
    public enum Ownership: Equatable, Sendable {
        case thisSession
        /// `OFFSIDER_LEASE` names another label.
        case otherLabel
        /// The lease file records no owner, as an older Offsider wrote it.
        case unrecorded
        /// The session that set it has exited.
        case ended(ProcessIdentity)
        /// The session that set it is still running, and the reader is not part of it.
        case other(ProcessIdentity)
    }

    /// `OFFSIDER_LEASE` decides when set, so two agents in one harness can tell their leases apart; otherwise the lease is this session's when its owner is among `ancestors` (the reader and its parents).
    public static func ownership(of lease: DeviceLease, sessionLabel: String?, ancestors: [ProcessIdentity], processes: ProcessTable) -> Ownership {
        if let sessionLabel = sessionLabel?.trimmingCharacters(in: .whitespaces), !sessionLabel.isEmpty {
            return sessionLabel == lease.label ? .thisSession : .otherLabel
        }
        guard let owner = lease.owner else { return .unrecorded }
        if ancestors.contains(where: { $0.isSameProcess(as: owner) }) { return .thisSession }
        return processes.isAlive(owner) ? .other(owner) : .ended(owner)
    }

    public static func lease(
        _ lease: DeviceLease?, device: String, sessionLabel: String?, ancestors: [ProcessIdentity], processes: ProcessTable, holder: DeviceLockHolder?
    ) -> DoctorRules.Verdict {
        let held = holder.map { holder in
            "; held now by pid \(holder.pid) (" + (holder.command.isEmpty ? "offsider" : "offsider \(holder.command)") + ")"
        } ?? ""
        guard let lease else { return (.pass, "Not leased" + held, nil) }
        let label = "'\(lease.label)'"
        let span = "since \(clock(lease.created)), until \(clock(lease.expires))"
        switch ownership(of: lease, sessionLabel: sessionLabel, ancestors: ancestors, processes: processes) {
        case .thisSession:
            return (.pass, "This session's lease: \(label) \(span)" + held, nil)
        case .otherLabel, .unrecorded:
            return (
                .warn,
                "Leased to another session: \(label) \(span)" + held,
                "Choose another device from `offsider devices`, or set OFFSIDER_LEASE to the lease's label if it is yours."
            )
        case .ended(let owner):
            return (
                .warn,
                "Leased to \(label) by a session that has ended (\(owner.name), pid \(owner.pid)) \(span)" + held,
                "If it was yours, `offsider lease set --device \(device) --label \(shellQuoted(lease.label))` renews it for this session; otherwise `lease set --force` with your own label takes it over."
            )
        case .other(let owner):
            return (
                .warn,
                "Leased to \(label) by another session (\(owner.name), pid \(owner.pid)) \(span)" + held,
                "If you set this lease, add OFFSIDER_LEASE=\(shellQuoted(lease.label)) to this command; otherwise choose another device from `offsider devices`."
            )
        }
    }

    /// Local `HH:MM`.
    public static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// A label as one single-quoted shell word.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
