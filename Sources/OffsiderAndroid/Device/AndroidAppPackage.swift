import Foundation
import OffsiderCore

/// One app's shell scripts and the parsers for what they print; each script names the package and nothing else.
enum AndroidAppPackage {
    static let marker = "offsider:"
    static let zoneMarker = "offsider: zone"

    static func infoScript(package: String) -> String {
        let quoted = ExpoDevClient.shellQuote(package)
        return "dumpsys package \(quoted); echo '\(zoneMarker)'; getprop persist.sys.timezone; getprop ro.build.version.sdk"
    }

    /// Whether the app is installed and running, then the optional stop, so one round trip answers both.
    private static func preamble(_ quoted: String, stop: Bool) -> String {
        """
        p=\(quoted)
        [ -n "$(pm path "$p" 2>/dev/null)" ] || { echo '\(marker) not-installed'; exit 0; }
        if pidof "$p" >/dev/null 2>&1; then echo '\(marker) running'; else echo '\(marker) stopped'; fi
        \(stop ? "am force-stop \"$p\"" : ":")
        """
    }

    /// The launcher's own intent and flags, so a running app's task comes to the front as a tap on its icon brings it.
    static func launchScript(package: String, restart: Bool) -> String {
        preamble(ExpoDevClient.shellQuote(package), stop: restart) + """

        c=$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$p" 2>/dev/null | tail -n 1)
        case "$c" in "$p"/*) am start -W -f 0x10200000 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "$c" ;; *) echo '\(marker) no-launcher' ;; esac
        """
    }

    static func stopScript(package: String) -> String {
        preamble(ExpoDevClient.shellQuote(package), stop: true)
    }

    /// The trailing package limits the intent to that app; the link is single-quoted, so `&`, `?` and `;` reach it whole.
    static func openScript(url: String, package: String, restart: Bool) -> String {
        preamble(ExpoDevClient.shellQuote(package), stop: restart) + """

        am start -W -a android.intent.action.VIEW -d \(ExpoDevClient.shellQuote(url)) "$p"
        """
    }

    enum State: Equatable {
        case notInstalled
        case installed(running: Bool)
    }

    /// The preamble's line; nil when the script printed none, as when the shell failed.
    static func state(in output: String) -> State? {
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch line {
            case "\(marker) not-installed": return .notInstalled
            case "\(marker) running": return .installed(running: true)
            case "\(marker) stopped": return .installed(running: false)
            default: continue
            }
        }
        return nil
    }

    static func hasNoLauncher(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "\(marker) no-launcher" }
    }

    /// What `am start -W` printed: its `Status`, `LaunchState` (Android 10 and later), `TotalTime`, and its first `Error:` line.
    struct StartReply: Equatable {
        var status: String?
        var launchState: String?
        var totalTime: Int?
        var error: String?

        var unresolved: Bool { error?.contains("unable to resolve Intent") == true }
    }

    static func startReply(_ output: String) -> StartReply {
        var reply = StartReply()
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("Status:") {
                reply.status = value(after: "Status:", in: line)
            } else if line.hasPrefix("LaunchState:") {
                reply.launchState = value(after: "LaunchState:", in: line)?.split(separator: " ").first.map(String.init)
            } else if line.hasPrefix("TotalTime:") {
                // 0 when the app was already in front and nothing started.
                reply.totalTime = value(after: "TotalTime:", in: line).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            } else if line.hasPrefix("Error:"), reply.error == nil {
                reply.error = line
            }
        }
        return reply
    }

    /// `LaunchState` when Android named one (`UNKNOWN` when the app was already in front), else whether the process was running before.
    static func start(launchState: String?, wasRunning: Bool, restarted: Bool) -> AppStart {
        if restarted { return .cold }
        switch launchState?.uppercased() {
        case "COLD": return .cold
        case "WARM", "HOT", "RELAUNCH": return .warm
        default: return wasRunning ? .warm : .cold
        }
    }

    private static func value(after prefix: String, in line: String) -> String? {
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    // MARK: dumpsys package

    /// The package's own section of `dumpsys package <pkg>`, nil when it has none; local times without the device's zone are left out.
    static func info(_ output: String, package: String) -> AppInfo? {
        let parts = output.components(separatedBy: "\n\(zoneMarker)\n")
        let dump = parts[0]
        let tail = parts.count > 1 ? parts[1].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } : []
        let zone = tail.first.flatMap { $0.isEmpty ? nil : TimeZone(identifier: $0) }
        let sdk = tail.count > 1 ? Int(tail[1]) : nil
        guard let section = section(of: package, in: dump) else { return nil }
        var info = AppInfo(app: package)
        var notificationsSeen = false
        for raw in section {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("versionName=") {
                info.version = info.version ?? rest(of: line, after: "versionName=")
            } else if line.hasPrefix("versionCode=") {
                info.build = info.build ?? line.split(separator: " ").first.map { String($0.dropFirst("versionCode=".count)) }
            } else if line.hasPrefix("installerPackageName=") {
                info.installer = info.installer ?? rest(of: line, after: "installerPackageName=")
            } else if line.hasPrefix("firstInstallTime=") {
                info.firstInstalled = info.firstInstalled ?? date(rest(of: line, after: "firstInstallTime="), zone: zone)
            } else if line.hasPrefix("lastUpdateTime=") {
                info.lastUpdated = info.lastUpdated ?? date(rest(of: line, after: "lastUpdateTime="), zone: zone)
            } else if line.hasPrefix("flags=["), info.debuggable == nil {
                info.debuggable = line.split(separator: " ").contains("DEBUGGABLE")
            } else if line.hasPrefix("android.permission.POST_NOTIFICATIONS: granted="), !notificationsSeen {
                notificationsSeen = true
                info.notifications = line.contains("granted=true")
            }
        }
        if let sdk, sdk < 33 { info.notifications = nil }
        return info
    }

    /// The lines under `Package [<pkg>]`, the first such header after `Packages:`, up to the next line indented no deeper.
    static func section(of package: String, in dump: String) -> [Substring]? {
        let lines = dump.split(separator: "\n", omittingEmptySubsequences: false)
        let header = "Package [\(package)]"
        let start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(header) }
        guard let start else { return nil }
        let indent = lines[start].prefix { $0 == " " }.count
        var body: [Substring] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.prefix(while: { $0 == " " }).count <= indent { break }
            body.append(line)
        }
        return body
    }

    private static func rest(of line: String, after prefix: String) -> String? {
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "null" ? nil : value
    }

    private static func date(_ text: String?, zone: TimeZone?) -> Date? {
        guard let text, let zone else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
