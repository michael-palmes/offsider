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
        let androidOnly = report.device?.platform == "android"
        var lines: [String] = []
        if androidOnly {
            lines.append("Offsider doctor: " + androidHeader(report.android))
        } else {
            lines.append(header(report.xcode))
            if let android = report.android {
                lines.append(androidHeader(android))
            }
        }
        for check in report.checks {
            let detail = check.status == .skip ? "Skipped: \(check.detail)" : check.detail
            lines.append("\(symbol(for: check.status)) \(padded(check.id.rawValue, idColumnWidth))\(detail)")
            if check.status == .warn || check.status == .fail, let hint = check.hint {
                lines.append("    Fix: \(hint)")
            }
        }
        if !androidOnly {
            lines += bootedLines(report.booted)
        }
        if let android = report.android {
            let emulators = android.devices.filter { $0.kind == "emulator" }
            if emulators.isEmpty {
                lines.append("Running emulators: none")
            } else {
                lines.append("Running emulators:")
                let nameWidth = (emulators.map { ($0.avd ?? $0.serial).count }.max() ?? 0) + 2
                for emulator in emulators {
                    var row = "  \(padded(emulator.avd ?? emulator.serial, nameWidth))\(emulator.serial)  \(emulator.state)"
                    if let api = emulator.apiLevel { row += "  API \(api)" }
                    lines.append(row)
                }
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

    static func bootedLines(_ booted: [BootedSimulator]) -> [String] {
        guard !booted.isEmpty else { return ["Booted simulators: none"] }
        let nameWidth = (booted.map(\.name.count).max() ?? 0) + 2
        return ["Booted simulators:"] + booted.map { "  \(padded($0.name, nameWidth))\($0.udid)  \($0.osVersion)" }
    }

    static func androidHeader(_ android: AndroidSummary?) -> String {
        guard let android else { return "Android SDK not found" }
        var text = "Android SDK \(android.sdkRoot) (\(android.sdkSource))"
        if let version = android.adbVersion { text += ", adb \(version)" }
        if let server = android.adbServer { text += ", server \(server)" }
        return text
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
