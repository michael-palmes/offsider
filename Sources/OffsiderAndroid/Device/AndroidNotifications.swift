import Foundation
import OffsiderCore

/// Selects one package's posted notifications on the device, so no other app's notification text crosses the cable.
enum AndroidNotifications {
    static let keysMarker = "offsider: keys"
    static let dumpMarker = "offsider: dump"
    static let recordMarker = "offsider: record"
    static let listMarker = "offsider: list"
    static let maximumValue = 4_096

    /// Android 11 and later pick each record by its key (`list`, then `get`); before that a filter keeps the package's blocks of the active list.
    static func script(package: String) -> String {
        """
        p=\(ExpoDevClient.shellQuote(package))
        if keys=$(cmd notification list 2>/dev/null); then
          echo '\(keysMarker)'
          printf '%s\\n' "$keys" | while IFS= read -r k; do
            r="${k#*"|"}"
            case "$r" in "$p|"*) echo '\(recordMarker)'; cmd notification get "$k" </dev/null 2>/dev/null ;; esac
          done
        else
          echo '\(dumpMarker)'
          dumpsys notification --noredact 2>/dev/null | while IFS= read -r l; do
            case "$l" in
              "  Notification List:"*) s=1; o=0; echo '\(listMarker)'; continue ;;
              "    NotificationRecord("*) o=0; if [ "$s" = 1 ]; then case "$l" in *" pkg=$p "*) o=1; echo '\(recordMarker)' ;; esac; fi ;;
              "  "[!\\ ]*:|" "[!\\ ]*:|[!\\ ]*:) o=0; s=0 ;;
            esac
            [ "$o" = 1 ] && printf '%s\\n' "$l"
          done
        fi
        """
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
                var value = String(line.dropFirst(extra.prefix.count))
                while !value.hasSuffix(")"), index < lines.count, extraName(lines[index].trimmingCharacters(in: .whitespaces)) == nil,
                      lines[index].trimmingCharacters(in: .whitespaces) != "}", value.count < maximumValue {
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

    /// The key of an `extras` line, which ends a value that ran over several lines.
    private static func extraName(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equals]
        guard name.hasPrefix("android."), !name.contains(" ") else { return nil }
        return String(name)
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
