import Foundation
import OffsiderCore

/// The scripts and parsers behind `app uninstall`, `prefs` and `broadcast`.
extension AndroidAppPackage {
    // MARK: Install

    /// `-r` replaces, `-t` takes a test-only build, and `--pkg` makes Android itself refuse an APK declaring anything else.
    static func installService(package: String, size: Int) -> String {
        "exec:cmd package install -r -t -S \(size) --pkg \(package)"
    }

    static func installedScript(package: String) -> String {
        preamble(ExpoDevClient.shellQuote(package), stop: false)
    }

    enum InstallReply: Equatable {
        case success
        case failure(code: String)
        case unknown
    }

    /// `Success`, or `Failure [INSTALL_FAILED_X: why]`; only the code is kept, since the rest may quote the APK.
    static func installReply(_ output: String) -> InstallReply {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("Success") { return .success }
        for line in lines {
            guard let bracket = line.range(of: "Failure ["), let code = line[bracket.upperBound...].prefixMatch(of: #/[A-Z_0-9]+/#) else { continue }
            return .failure(code: String(code.output))
        }
        return .unknown
    }

    /// One line a person can act on for the failures that have a known fix.
    static func installFailure(code: String, package: String, device: String) -> AppLifecycleError {
        let uninstall = "offsider app uninstall --app \(package) --device \(device)"
        switch code {
        case "INSTALL_FAILED_INVALID_APK":
            return AppLifecycleError(.packageMismatch, "Android found this APK does not declare \(package), so it installed nothing. Build \(package), or pass the APK's own package with --app.")
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE", "INSTALL_FAILED_VERSION_DOWNGRADE":
            return AppLifecycleError(.installFailed, "\(package) on \(device) is signed differently or newer, so Android refused to replace it (\(code)). Removing it deletes its data: `\(uninstall)`.")
        case "INSTALL_FAILED_NO_MATCHING_ABIS":
            return AppLifecycleError(.installFailed, "This APK has no native code for \(device)'s CPU (\(code)). Build it for arm64-v8a.")
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE":
            return AppLifecycleError(.installFailed, "\(device) has no room for this APK (\(code)). Free some space, then run the same command again.")
        case "INSTALL_FAILED_USER_RESTRICTED", "INSTALL_FAILED_VERIFICATION_FAILURE", "INSTALL_FAILED_ABORTED":
            return AppLifecycleError(.installFailed, "\(device) blocked the install (\(code)). Can you allow installs over USB on \(device), and answer any prompt on its screen? Then run the same command again.")
        default:
            return AppLifecycleError(.installFailed, "Android refused to install \(package) on \(device) (\(code)).")
        }
    }

    // MARK: Uninstall

    static func uninstallScript(package: String) -> String {
        preamble(ExpoDevClient.shellQuote(package), stop: false) + "\npm uninstall \"$p\""
    }

    // MARK: Preferences

    static let prefsDoneMarker = "\(marker) done"
    static let prefsFileMarker = "\(marker) file "
    static let prefsBinaryMarker = "\(marker) binary"
    static let keyTypes = ["string", "int", "long", "float", "boolean", "set"]
    static let maximumKeyCharacters = 200

    /// Names and types only: the device filters the file, so no value ever crosses adb. Text inside a value has its `<` escaped, and `grep -o` prints nothing but each match.
    static func prefsScript(package: String) -> String {
        let types = keyTypes.joined(separator: "|")
        let script = """
        cd shared_prefs 2>/dev/null || { echo '\(prefsDoneMarker)'; exit 0; }
        for f in *.xml; do
          [ -f "$f" ] || continue
          printf '\(prefsFileMarker)%s\\n' "$f"
          case "$(head -c 3 "$f" 2>/dev/null)" in ABX) echo '\(prefsBinaryMarker)'; continue ;; esac
          grep -oE '<(\(types)) name="[^"]*"' "$f" 2>/dev/null
        done
        echo '\(prefsDoneMarker)'
        """
        return "run-as \(ExpoDevClient.shellQuote(package)) sh -c \(ExpoDevClient.shellQuote(script))"
    }

    /// The script's markers and key lines; any other line is dropped unread, so nothing unexpected can reach the output. Nil without the closing marker.
    static func preferences(_ stdout: String, package: String) -> AppPreferences? {
        let lines = stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.contains(prefsDoneMarker) else { return nil }
        var files: [AppPreferenceFile] = []
        for line in lines {
            if line.hasPrefix(prefsFileMarker) {
                files.append(AppPreferenceFile(name: shown(String(line.dropFirst(prefsFileMarker.count))), keys: []))
            } else if line == prefsBinaryMarker, !files.isEmpty {
                files[files.count - 1].binary = true
            } else if let key = preferenceKey(line), !files.isEmpty {
                files[files.count - 1].keys.append(key)
            }
        }
        for index in files.indices { files[index].keys.sort { $0.name < $1.name } }
        return AppPreferences(app: package, files: files)
    }

    static func preferenceKey(_ line: String) -> AppPreferenceFile.Key? {
        guard let match = line.wholeMatch(of: #/<([a-z]+) name="([^"]*)"/#), keyTypes.contains(String(match.1)) else { return nil }
        return AppPreferenceFile.Key(name: shown(decoded(String(match.2))), type: String(match.1))
    }

    /// A name holding a token's shape is masked as a log line would be, and a very long one cut: such a key is data, not a name.
    private static func shown(_ name: String) -> String {
        let masked = LogRedactor.redact(name).text
        return masked.count > maximumKeyCharacters ? String(masked.prefix(maximumKeyCharacters)) + "…" : masked
    }

    private static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&#10;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `run-as`'s own refusal: it runs before the script, so its lines never hold a value. Anything else stays out of the message.
    static func runAsLine(_ stderr: String) -> String? {
        stderr.split(whereSeparator: \.isNewline).first { $0.hasPrefix("run-as:") }.map { TerminalText.line(String($0), cap: 200) }
    }

    // MARK: Broadcast

    struct Receiver: Equatable {
        let name: String
        let exported: Bool
    }

    /// A named receiver is looked up alone, since an explicit send ignores its intent filters; otherwise what the manifest lists for the action.
    static func receiversScript(action: String, receiver: String?, package: String) -> String {
        let query = receiver.map { "-n \"$p\"/\(ExpoDevClient.shellQuote($0))" } ?? "-a \(ExpoDevClient.shellQuote(action)) -p \"$p\""
        return preamble(ExpoDevClient.shellQuote(package), stop: false) + "\ncmd package query-receivers \(query) 2>&1"
    }

    /// `-n` or `-p`, so it reaches only this app. A stopped app ignores a broadcast unless told otherwise, and with no word of it.
    static func broadcastScript(action: String, receiver: String?, package: String) -> String {
        let target = receiver.map { "-n \(ExpoDevClient.shellQuote(package))/\(ExpoDevClient.shellQuote($0))" } ?? "-p \(ExpoDevClient.shellQuote(package))"
        return "am broadcast --include-stopped-packages -a \(ExpoDevClient.shellQuote(action)) \(target) 2>&1"
    }

    /// Each `Receiver #n:` block's class and whether it is exported; the first of each, as a nested `ApplicationInfo` repeats those words.
    static func receivers(_ output: String) -> [Receiver] {
        var found: [Receiver] = []
        var name: String?
        var exported: Bool?
        let flush = {
            if let current = name { found.append(Receiver(name: current, exported: exported ?? false)) }
            name = nil
            exported = nil
        }
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Receiver #") {
                flush()
            } else if name == nil, line.hasPrefix("name="), line.dropFirst(5).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._$".contains($0)) }) {
                name = String(line.dropFirst(5))
            } else if exported == nil, line.hasPrefix("enabled="), let match = line.firstMatch(of: #/exported=(true|false)/#) {
                exported = match.1 == "true"
            }
        }
        flush()
        return found
    }

    enum BroadcastReply: Equatable {
        case completed(resultCode: Int?)
        case denied
        case unknown
    }

    /// The completed line first, as `data=` on it is the app's own text; then Android's words for a protected action, in either form.
    static func broadcastReply(_ output: String) -> BroadcastReply {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("Broadcast completed:") {
            return .completed(resultCode: line.firstMatch(of: #/result=(-?[0-9]+)/#).flatMap { Int($0.1) })
        }
        return output.contains("Permission Denial") || output.contains("SecurityException") ? .denied : .unknown
    }

    /// The custom actions the app's receivers declare in `dumpsys package`, to name in a refusal; Android's own stay out, as the shell cannot send them.
    static func declaredActions(_ dump: String, package: String) -> [String] {
        var actions: [String] = []
        var inTable = false
        var pending: String?
        for raw in dump.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("Receiver Resolver Table:") {
                inTable = true
            } else if inTable, !raw.hasPrefix(" ") {
                break
            } else if inTable, line.hasSuffix(":"), !line.contains(" ") {
                pending = String(line.dropLast())
            } else if inTable, let action = pending, line.contains(" \(package)/") {
                if !action.hasPrefix("android."), action.contains("."), (try? AppBroadcastName.validate(action: action)) != nil, !actions.contains(action) { actions.append(action) }
            }
        }
        return actions
    }
}

/// Airplane mode Offsider turned on, kept until `airplane off`, `session stop` or `devices remove` takes it off. It outlives a reboot, unlike a posture override.
struct AndroidAirplaneRecord: AndroidSerialRecord, Equatable, Sendable {
    static let maximumBytes = 1_024
    static let directoryName = "airplane"
    static let readScript = "settings get global airplane_mode_on"

    let serial: String
    /// An emulator's serial is only its port, so another AVD can take it and this AVD can move; a phone's serial is its own and this stays nil.
    let avd: String?

    /// What a device with this record is called while it is not running, which `session stop --device` takes.
    var name: String { avd ?? serial }

    static func script(enabled: Bool) -> String {
        "cmd connectivity airplane-mode \(enabled ? "enable" : "disable")"
    }

    static func parseSetting(_ output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0", "null": return false
        default: return nil
        }
    }

    func encoded() -> Data {
        var object: [String: Any] = ["serial": serial]
        if let avd { object["avd"] = avd }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    init(serial: String, avd: String?) {
        self.serial = serial
        self.avd = avd
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let serial = object["serial"] as? String else { return nil }
        self.init(serial: serial, avd: object["avd"] as? String)
    }
}

typealias AndroidAirplaneRecordStore = AndroidSerialRecordStore<AndroidAirplaneRecord>
