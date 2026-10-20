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
        let iosDeviceOnly = report.device?.platform == "ios" && report.device?.kind == "physical"
        let androidOnly = report.device?.platform == "android" || iosDeviceOnly
        var lines: [String] = []
        if iosDeviceOnly {
            lines.append(iosDeviceHeader(report))
        } else if androidOnly {
            lines.append("Offsider doctor: " + androidHeader(report.android))
        } else {
            lines.append(header(report.xcode))
            if let android = report.android {
                lines.append(androidHeader(android))
            }
        }
        if let host = report.host {
            lines.append("Host: " + host.summary)
        }
        if let device = report.device, device.source == "environment" {
            lines.append("Device: \(device.id)" + (device.name.map { " (\($0))" } ?? "") + ", from OFFSIDER_DEVICE")
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

    static func iosDeviceHeader(_ report: DoctorReport) -> String {
        var text = "Offsider doctor: "
        if let version = report.xcode.version {
            text += "Xcode \(version)" + (report.xcode.build.map { " (\($0))" } ?? "") + ", "
        }
        let device = report.device.map { DeviceName.display($0.id, label: $0.name) } ?? "iPhone"
        return text + device
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

// MARK: Person

extension DoctorRenderer {
    /// A person's report: the header, the checks under This Mac, Android and the device, a `Fix` under each problem,
    /// what is running, the fixes applied, then one closing line. Rows never cut a detail; it wraps under itself.
    public static func person(_ report: DoctorReport, canvas: Canvas) -> String {
        let style = canvas.style
        let idWidth = (report.checks.map(\.id.rawValue.count) + report.fixes.map(\.id.rawValue.count)).max() ?? 0
        let column = 4 + idWidth + 2
        let stacked = canvas.breakpoint == .narrow || canvas.usable - column < 24
        let geometry = RowGeometry(column: stacked ? 4 : column, stacked: stacked, idWidth: idWidth, usable: canvas.usable)
        var blocks: [[String]] = []
        for section in sections(report) where !section.checks.isEmpty {
            let note = section.note.map { "  " + style.dim($0) } ?? ""
            blocks.append(["  " + style.bold(section.title) + note] + section.checks.flatMap { row($0, geometry: geometry, style: style) })
        }
        if report.device == nil { blocks.append(running(report, canvas: canvas)) }
        if !report.fixes.isEmpty {
            blocks.append(["  " + style.bold("Fixes")] + report.fixes.flatMap { fix in
                let status: RowStatus = fix.outcome == .applied ? .ok : fix.outcome == .failed ? .fail : .skip
                return row(id: fix.id.rawValue, status: status, detail: fix.detail, hint: nil, geometry: geometry, style: style)
            })
        }
        blocks.append([closing(report, style: style)])
        let summary = personSummary(report, style: style)
        let mark = style.ascii ? "" : TerminalStyle.Mark.doctor.emoji + "  "
        let widest = blocks.joined().map(TerminalText.width).max() ?? 0
        let frame = min(canvas.usable, max(widest, TerminalText.width(mark + "Doctor") + 2 + TerminalText.width(summary), 40))
        return ([headerLines(mark: mark, title: "Doctor", summary: summary, frame: frame, style: style)] + blocks)
            .map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
    }

    private struct RowGeometry {
        /// Where the detail starts; 4 when stacked under the id.
        var column: Int
        var stacked: Bool
        var idWidth: Int
        var usable: Int

        var detailWidth: Int { max(min(usable - column, PromptScreen.width(columns: usable)), 10) }
    }

    private struct Section {
        var title: String
        var note: String?
        var checks: [DoctorCheckResult]
    }

    /// This Mac, Android and the device, each keeping the report's order.
    private static func sections(_ report: DoctorReport) -> [Section] {
        func isDevice(_ id: DoctorCheckID) -> Bool {
            id.isPerSimulator || id.isPerAndroidDevice || id.isPerIOSDevice || id == .deviceLease || id == .devicePolicy
        }
        let device = report.device.map { TerminalText.field(DeviceName.display($0.id, label: $0.name), profile: .person) } ?? "Device"
        return [
            Section(title: "This Mac", checks: report.checks.filter { !$0.id.isAndroidHost && !isDevice($0.id) }),
            Section(title: "Android", checks: report.checks.filter { $0.id.isAndroidHost }),
            Section(title: device, note: report.device?.source == "environment" ? "from OFFSIDER_DEVICE" : nil, checks: report.checks.filter { isDevice($0.id) }),
        ]
    }

    private static func row(_ check: DoctorCheckResult, geometry: RowGeometry, style: TerminalStyle) -> [String] {
        let status: RowStatus
        switch check.status {
        case .pass: status = .ok
        case .warn: status = .warn
        case .fail: status = .fail
        case .skip: status = .skip
        }
        let problem = check.status == .warn || check.status == .fail
        return row(id: check.id.rawValue, status: status, detail: check.detail, hint: problem ? check.hint : nil, geometry: geometry, style: style)
    }

    /// `  ✓ id  detail`, the detail wrapped under itself, then `Fix  <command>` under a problem.
    private static func row(id: String, status: RowStatus, detail: String, hint: String?, geometry: RowGeometry, style: TerminalStyle) -> [String] {
        let indent = String(repeating: " ", count: geometry.column)
        let tone: (String) -> String = status == .skip ? style.dim : { $0 }
        let wrapped = PromptScreen.wrap(TerminalText.line(detail, cap: TerminalText.maxErrorCharacters, keepsTab: false), width: geometry.detailWidth).map(tone)
        let head = "  " + style.status(status) + " " + style.dim(id)
        var lines: [String]
        if geometry.stacked {
            lines = [head] + wrapped.filter { !$0.isEmpty }.map { indent + $0 }
        } else if let first = wrapped.first, !first.isEmpty {
            lines = [head + String(repeating: " ", count: max(geometry.idWidth - id.count, 0) + 2) + first] + wrapped.dropFirst().map { indent + $0 }
        } else {
            lines = [head]
        }
        guard let hint, !hint.isEmpty else { return lines }
        let label = indent + style.dim("Fix") + "  "
        let shown = TerminalText.line(hint, cap: TerminalText.maxErrorCharacters, keepsTab: false)
        // A bare command stays whole and cyan; a sentence wraps with its `code` cyan.
        guard shown.hasSuffix(".") || shown.contains("`") else { return lines + [label + style.cyan(shown)] }
        let continuation = String(repeating: " ", count: geometry.column + 5)
        return lines + PromptScreen.wrap(shown, width: max(geometry.detailWidth - 5, 10)).enumerated().map { index, text in
            (index == 0 ? label : continuation) + TerminalText.codeSpans(text, style: style)
        }
    }

    /// Booted simulators and running emulators behind status dots, or one dim line when nothing runs.
    private static func running(_ report: DoctorReport, canvas: Canvas) -> [String] {
        let style = canvas.style
        let emulators = (report.android?.devices ?? []).filter { $0.kind == "emulator" }
        guard !report.booted.isEmpty || !emulators.isEmpty else { return ["  " + style.bold("Running") + "  " + style.dim("nothing booted")] }
        let rows = report.booted.map { simulator in
            Table.Row([Table.Cell(simulator.name, untrusted: true), Table.Cell(simulator.udid), Table.Cell(simulator.osVersion)], status: .on, group: "Running")
        } + emulators.map { emulator in
            Table.Row([
                Table.Cell(emulator.avd ?? emulator.serial, untrusted: true),
                Table.Cell(emulator.serial, person: emulator.avd == nil ? "" : nil, tag: emulator.state == "device" ? nil : emulator.state),
                emulator.apiLevel.map { Table.Cell("API \($0)") },
            ], status: emulator.state == "device" ? .on : .starting, group: "Running")
        }
        let table = Table(columns: [
            Table.Column(agent: nil, person: 0, fit: .cut(min: 12)),
            Table.Column(agent: nil, person: 1, fit: .whole, tone: .dim),
            Table.Column(agent: nil, person: 2, fit: .optional(priority: 1), tone: .dim),
        ], rows: rows)
        return PersonRenderer.table(table, canvas: canvas)
    }

    /// `✅  No problems found`, `⚠️  1 warning` or `❌  1 failure · 2 warnings`.
    private static func closing(_ report: DoctorReport, style: TerminalStyle) -> String {
        let gap = style.ascii ? " " : "  "
        let counts = problemCounts(report).joined(separator: " \(style.dot) ")
        if report.checks.contains(where: { $0.status == .fail }) { return style.mark(.cancel) + gap + style.red(style.bold(counts)) }
        if !counts.isEmpty { return style.yellow(style.mark(.warning) + gap) + style.yellow(style.bold(counts)) }
        return style.mark(.done) + gap + style.green(style.bold("No problems found"))
    }

    private static func problemCounts(_ report: DoctorReport) -> [String] {
        let failures = report.checks.filter { $0.status == .fail }.count
        let warnings = report.checks.filter { $0.status == .warn }.count
        return (failures > 0 ? [DoctorRules.plural(failures, "failure")] : []) + (warnings > 0 ? [DoctorRules.plural(warnings, "warning")] : [])
    }

    /// `Xcode 27.0 · 1 warning`, or the device's name in place of Xcode.
    private static func personSummary(_ report: DoctorReport, style: TerminalStyle) -> String {
        var parts: [String] = []
        if let device = report.device {
            parts.append(TerminalText.field(DeviceName.display(device.id, label: device.name), profile: .person))
        } else if let version = report.xcode.version {
            parts.append("Xcode \(version)")
        }
        let counts = problemCounts(report)
        return (parts + (counts.isEmpty ? ["all good"] : counts)).joined(separator: " \(style.dot) ")
    }

    /// The kit's header: the mark and bold title, the dim summary right-aligned at `frame` or under it, then a cyan rule.
    private static func headerLines(mark: String, title: String, summary: String, frame: Int, style: TerminalStyle) -> [String] {
        let titleWidth = TerminalText.width(mark + title)
        let summaryWidth = TerminalText.width(summary)
        let top = titleWidth + 2 + summaryWidth <= frame
            ? [mark + style.bold(title) + String(repeating: " ", count: frame - titleWidth - summaryWidth) + style.dim(summary)]
            : [mark + style.bold(title), "    " + style.dim(summary)]
        return top + [style.cyan(String(repeating: style.rule, count: frame))]
    }
}
