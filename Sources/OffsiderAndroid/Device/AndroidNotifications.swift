import Foundation
import OffsiderCore

/// Selects one package's posted notifications on the device, so no other app's notification text crosses the cable.
enum AndroidNotifications {
    static let keysMarker = "offsider: keys"
    static let dumpMarker = "offsider: dump"
    static let recordMarker = "offsider: record"
    static let listMarker = "offsider: list"
    static let notInstalledMarker = "offsider: not-installed"
    static let maximumValue = 4_096

    /// Android 11 and later pick each record by its key (`list`, then `get`); before that a filter keeps the package's blocks of the active list. With no record, `pm path` tells a mistyped package from an app with nothing posted.
    static func script(package: String) -> String {
        """
        p=\(ExpoDevClient.shellQuote(package))
        n() { [ -n "$(pm path "$p" 2>/dev/null)" ] || echo '\(notInstalledMarker)'; }
        if keys=$(cmd notification list 2>/dev/null); then
          echo '\(keysMarker)'
          case "$keys" in *"|$p|"*) ;; *) n ;; esac
          printf '%s\\n' "$keys" | while IFS= read -r k; do
            r="${k#*"|"}"
            case "$r" in "$p|"*) echo '\(recordMarker)'; cmd notification get "$k" </dev/null 2>/dev/null ;; esac
          done
        else
          echo '\(dumpMarker)'
          dumpsys notification --noredact 2>/dev/null | {
            while IFS= read -r l; do
              case "$l" in
                "  Notification List:"*) s=1; o=0; echo '\(listMarker)'; continue ;;
                "    NotificationRecord("*) o=0; if [ "$s" = 1 ]; then case "$l" in *" pkg=$p "*) o=1; f=1; echo '\(recordMarker)' ;; esac; fi ;;
                "  mArchive"*|"  "[!\\ ]*:|" "[!\\ ]*:) o=0; s=0 ;;
              esac
              [ "$o" = 1 ] && printf '%s\\n' "$l"
            done
            [ "$f" = 1 ] || n
          }
        fi
        """
    }

    /// True when the script found no record and `pm path` found no app; a line of the app's own text cannot pass for it, as it prints only with no record.
    static func notInstalled(_ output: String) -> Bool {
        let lines = output.components(separatedBy: "\n")
        return lines.contains(notInstalledMarker) && !lines.contains(recordMarker)
    }

    /// The app's checked records without Android's own group summaries or empty ones; nil when no list was found, which is not "none posted".
    static func parse(_ output: String, package: String) -> NotificationSnapshot? {
        let lines = output.components(separatedBy: "\n")
        let source: NotificationSnapshot.Source
        if lines.contains(keysMarker) {
            source = .keys
        } else if lines.contains(dumpMarker), lines.contains(listMarker) {
            source = .dump
        } else {
            return nil
        }
        var records: [[String]] = []
        for line in lines {
            if line == recordMarker {
                records.append([])
            } else if !records.isEmpty {
                records[records.count - 1].append(line)
            }
        }
        var seen = Set<String>()
        let notifications = records.compactMap { record(from: $0, package: package) }.filter { seen.insert($0.key).inserted }
        return NotificationSnapshot(notifications: notifications, source: source)
    }

    static func record(from lines: [String], package: String) -> PostedNotification? {
        guard let header = lines.first?.trimmingCharacters(in: .whitespaces), header.hasPrefix("NotificationRecord("),
              header.contains(" pkg=\(package) "), let key = field("key=", in: header, until: ": Notification(") else { return nil }
        let keyParts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard keyParts.count >= 2, keyParts[1] == package else { return nil }
        let notification = header.range(of: ": Notification(").map { String(header[$0.upperBound...]) } ?? ""
        let flags = field("flags=", in: notification, until: " ") ?? ""
        if flags.contains("AUTOGROUP_SUMMARY") { return nil }
        var posted = PostedNotification(
            key: key,
            id: field("id=", in: header, until: " ").flatMap { Int($0) },
            tag: field("tag=", in: header, until: " importance=").flatMap { $0 == "null" ? nil : $0 },
            channel: field("channel=", in: notification, until: " ").flatMap { $0 == "null" ? nil : $0 },
            ongoing: flags.split(separator: "|").contains("ONGOING_EVENT")
        )
        var when: Date?
        var index = 1
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.hasPrefix("mCreationTimeMs="), posted.postedAt == nil {
                posted.postedAt = milliseconds(line.dropFirst("mCreationTimeMs=".count))
            } else if line.hasPrefix("when="), when == nil {
                when = milliseconds(line.dropFirst("when=".count).prefix { $0.isNumber })
            } else if let extra = textExtra(line) {
                let indent = lines[index - 1].prefix { $0 == " " }.count
                var value = String(line.dropFirst(extra.prefix.count))
                while index < lines.count, value.count < maximumValue, !(value.hasSuffix(")") && endsValue(lines[index], indent: indent)) {
                    value += "\n" + lines[index]
                    index += 1
                }
                let text = value.hasSuffix(")") ? String(value.dropLast()) : value
                let capped = String(text.prefix(maximumValue))
                switch extra.name {
                case "android.title": posted.title = posted.title ?? capped
                case "android.text": posted.text = posted.text ?? capped
                case "android.bigText": posted.bigText = posted.bigText ?? capped
                case "android.subText": posted.subText = posted.subText ?? capped
                default: break
                }
            }
        }
        posted.postedAt = posted.postedAt ?? when
        guard [posted.title, posted.text, posted.bigText, posted.subText].contains(where: { $0?.isEmpty == false }) else { return nil }
        return posted
    }

    static let textExtras = ["android.title", "android.text", "android.bigText", "android.subText"]

    /// `android.title=String (Order filled)`, also `SpannableString (…)`; `null` values carry no text.
    private static func textExtra(_ line: String) -> (name: String, prefix: String)? {
        guard let name = extraName(line), textExtras.contains(name) else { return nil }
        let rest = line.dropFirst(name.count + 1)
        guard let open = rest.range(of: " ("), !rest[..<open.lowerBound].contains(" ") else { return nil }
        return (name, String(line[..<open.upperBound]))
    }

    /// The key of an `android.` entry in `extras`.
    private static func extraName(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equals]
        guard name.hasPrefix("android."), !name.contains(" ") else { return nil }
        return String(name)
    }

    /// The line after a value's closing `)`: the next entry of any key at the value's own indent, or the block's closing brace further out. Android prints a value's later lines as they are, with no indent of its own.
    private static func endsValue(_ line: String, indent: Int) -> Bool {
        let own = line.prefix { $0 == " " }.count
        let trimmed = line.dropFirst(own)
        if trimmed == "}" { return own < indent }
        guard own == indent, let equals = trimmed.firstIndex(of: "=") else { return false }
        return equals > trimmed.startIndex && !trimmed[..<equals].contains(" ")
    }

    private static func field(_ name: String, in text: String, until end: String) -> String? {
        guard let start = text.range(of: name) else { return nil }
        let rest = text[start.upperBound...]
        let value = rest.range(of: end).map { rest[..<$0.lowerBound] } ?? rest
        return value.isEmpty ? nil : String(value)
    }

    private static func milliseconds<S: StringProtocol>(_ text: S) -> Date? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
