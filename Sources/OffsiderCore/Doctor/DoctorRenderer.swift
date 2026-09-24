import Foundation

public enum DoctorRenderer {
    static let idColumnWidth = (DoctorCheckID.allCases.map(\.rawValue.count).max() ?? 0) + 2

    public static func symbol(for status: CheckStatus) -> String {
        switch status {
        case .pass: return "✓"
        case .warn: return "!"
        case .fail: return "✗"
        case .skip: return "-"
        }
    }

    public static func render(_ report: DoctorReport) -> String {
        var lines: [String] = [header(report.xcode)]
        for check in report.checks {
            let detail = check.status == .skip ? "Skipped: \(check.detail)" : check.detail
            lines.append("\(symbol(for: check.status)) \(padded(check.id.rawValue, idColumnWidth))\(detail)")
            if check.status == .warn || check.status == .fail, let hint = check.hint {
                lines.append("    Fix: \(hint)")
            }
        }
        if report.booted.isEmpty {
            lines.append("Booted simulators: none")
        } else {
            lines.append("Booted simulators:")
            let nameWidth = (report.booted.map(\.name.count).max() ?? 0) + 2
            for simulator in report.booted {
                lines.append("  \(padded(simulator.name, nameWidth))\(simulator.udid)  \(simulator.osVersion)")
            }
        }
        if !report.fixes.isEmpty {
            lines.append("Fixes:")
            let idWidth = (report.fixes.map(\.id.rawValue.count).max() ?? 0) + 2
            for fix in report.fixes {
                lines.append("  \(padded(fix.outcome.rawValue, 9))\(padded(fix.id.rawValue, idWidth))\(fix.detail)")
            }
        }
        lines.append(resultLine(report))
        return lines.joined(separator: "\n") + "\n"
    }

    static func header(_ xcode: XcodeSummary) -> String {
        var xcodePart = "Xcode \(xcode.version ?? "unknown")"
        if let build = xcode.build { xcodePart += " (\(build))" }
        return "Offsider doctor: \(xcodePart), CoreSimulator \(xcode.coreSimulator ?? "unknown")"
    }

    static func resultLine(_ report: DoctorReport) -> String {
        let warnings = report.checks.filter { $0.status == .warn }.count
        let failures = report.checks.filter { $0.status == .fail }.count
        var parts: [String] = []
        if warnings > 0 { parts.append(DoctorRules.plural(warnings, "warning")) }
        if failures > 0 { parts.append(DoctorRules.plural(failures, "failure")) }
        return "Result: " + (parts.isEmpty ? "no problems found" : parts.joined(separator: ", "))
    }

    static func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
