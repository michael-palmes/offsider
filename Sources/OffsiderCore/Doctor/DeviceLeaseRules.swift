import Foundation

/// `device.lease`, on every device report: an advisory lease another session holds is a warning, never a failure.
public enum DeviceLeaseRules {
    public static let sessionVariable = "OFFSIDER_LEASE"

    public static func lease(_ lease: DeviceLease?, sessionLabel: String?, holder: DeviceLockHolder?, now: Date = Date()) -> DoctorRules.Verdict {
        let held = holder.map { holder in
            "; held now by pid \(holder.pid) (" + (holder.command.isEmpty ? "offsider" : "offsider \(holder.command)") + ")"
        } ?? ""
        guard let lease else { return (.pass, "Not leased" + held, nil) }
        let detail = "'\(lease.label)' since \(clock(lease.created)), until \(clock(lease.expires))"
        if let sessionLabel, sessionLabel.trimmingCharacters(in: .whitespaces) == lease.label {
            return (.pass, "This session's lease: " + detail + held, nil)
        }
        return (
            .warn,
            "Leased to another session: " + detail + held,
            "Choose another device from `offsider list-devices`, or set OFFSIDER_LEASE to the lease's label if it is yours."
        )
    }

    /// Local `HH:MM`.
    public static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
