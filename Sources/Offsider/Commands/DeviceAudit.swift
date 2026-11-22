import ArgumentParser
import Foundation
import OffsiderCore

/// `devices status --audit [--last <n>]`: the newest records of the physical-device audit trail.
struct DeviceAuditOptions: ParsableArguments {
    @Flag(name: .customLong("audit"), help: "Show the newest records of the physical-device audit trail; with --device, only that device's. Always exits 0.")
    var audit = false

    @Option(name: .customLong("last"), help: ArgumentHelp("With --audit: how many records to show, 1 to 1000 (default 20).", valueName: "n"))
    var last: Int?

    func validate() throws {
        if last != nil, !audit { throw ValidationError("--last goes with --audit.") }
        if let last, !AuditTrail.lastRange.contains(last) {
            throw ValidationError("--last takes \(AuditTrail.lastRange.lowerBound) to \(AuditTrail.lastRange.upperBound); got \(last).")
        }
    }
}

extension DeviceAccessStatus {
    /// The records `--audit` asked for, oldest first; none when the account has no home folder.
    func auditRecords(context: DeviceAccessContext) throws -> (records: [AuditRecord], path: String) {
        let target = try device.map(DeviceAccess.physicalKey)
        guard let trail = context.store()?.audit else { return ([], "~/.config/offsider/\(AuditTrail.fileName)") }
        let key = target.map { AuditRecord.deviceKey(platform: $0.platform, key: $0.key) }
        return (trail.last(audit.last ?? AuditTrail.defaultLast, device: key), trail.path)
    }

    func showAudit(context: DeviceAccessContext, console: Console) throws {
        let (records, path) = try auditRecords(context: context)
        let policy = context.policy()
        if json {
            console.data(policy.statusJSON(now: context.now(), only: try device.map(DeviceAccess.physicalKey), audit: records))
            return
        }
        console.show(AuditScreen.page(records, list: policy.list, path: path, timeZone: context.timeZone))
    }
}
