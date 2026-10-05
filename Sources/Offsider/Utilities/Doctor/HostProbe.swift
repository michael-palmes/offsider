import Darwin
import Foundation
import OffsiderCore

/// Reads the host facts `doctor` reports; each read is a closure so tests run without the real Mac.
struct HostProbe {
    var loadAverage: () -> [Double]
    var cpuCount: () -> Int?
    var memoryBytes: () -> UInt64?
    var diskPath: () -> String
    var diskFreeBytes: (String) -> UInt64?
    var offsiderPids: () -> [Int32]
    var processArguments: (Int32) -> [UInt8]?
    var startTime: (Int32) -> Date?
    var isCommand: (String) -> Bool

    func facts() -> HostFacts {
        let path = diskPath()
        let gigabyte = 1_073_741_824.0
        let sessions = offsiderPids().compactMap { pid -> HostSession? in
            guard let buffer = processArguments(pid) else { return HostSession(pid: pid, command: nil, device: nil, startedAt: startTime(pid)) }
            let parsed = HostSessionParser.parse(buffer, isCommand: isCommand)
            return HostSession(pid: pid, command: parsed.command, device: parsed.device, startedAt: startTime(pid))
        }
        return HostFacts(
            loadAverage: loadAverage(),
            cpuCount: cpuCount(),
            memoryGB: memoryBytes().map { (Double($0) / gigabyte * 10).rounded() / 10 },
            diskFreeGB: diskFreeBytes(path).map { (Double($0) / gigabyte * 10).rounded() / 10 },
            diskPath: path,
            sessions: sessions
        )
    }

    static let live = HostProbe(
        loadAverage: {
            var values = [Double](repeating: 0, count: 3)
            return getloadavg(&values, 3) == 3 ? values : []
        },
        cpuCount: { sysctlValue("hw.logicalcpu", as: Int32.self).map(Int.init) },
        memoryBytes: { sysctlValue("hw.memsize", as: UInt64.self) },
        diskPath: { NSHomeDirectory() },
        diskFreeBytes: { path in
            var info = statfs()
            guard statfs(path, &info) == 0 else { return nil }
            return UInt64(info.f_bavail) * UInt64(info.f_bsize)
        },
        offsiderPids: { otherOffsiderPids() },
        processArguments: { procargs($0) },
        startTime: { ProcessStartTime.date(of: $0) },
        isCommand: { name in OffsiderCommand.configuration.subcommands.contains { $0._commandName == name } }
    )

    private static func sysctlValue<T>(_ name: String, as type: T.Type) -> T? {
        var value = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        var size = value.count
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    /// This user's `offsider` processes other than this one.
    private static func otherOffsiderPids() -> [Int32] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        let me = getpid()
        let uid = getuid()
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0, pid != me, DeviceLock.isOffsiderProcess(pid) else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == uid
        }.sorted()
    }

    /// The raw `KERN_PROCARGS2` buffer; only `HostSessionParser` reads it.
    static func procargs(_ pid: Int32) -> [UInt8]? {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(length))
    }
}
