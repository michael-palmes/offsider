import Foundation
@testable import OffsiderAndroid
import OffsiderCore
import Testing

/// The committed, scrubbed React Native playground trees under `Tests/Goldens/trees/<platform>/<screen>/`.
enum TreeGoldens {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens/trees")
    static let budgetsURL = root.appendingPathComponent("budgets.json")

    static let rawFile = "raw.json"
    static let jsonFile = "describe-ui.json"
    static let summaryFile = "summary.txt"
    static let textFile = "text.txt"
    static let files = [rawFile, jsonFile, summaryFile, textFile]

    static let textOptions = UITreeRenderOptions(format: .text)

    static var isUpdating: Bool {
        ProcessInfo.processInfo.environment["OFFSIDER_GOLDENS_UPDATE"] == "1"
    }

    static func placeholder(for platform: DevicePlatform) -> String {
        "<\(platform.rawValue)-device>"
    }

    struct Golden: Sendable, CustomTestStringConvertible {
        let platform: DevicePlatform
        let screen: String

        var name: String { "\(platform.rawValue)/\(screen)" }
        var directory: URL { TreeGoldens.root.appendingPathComponent(platform.rawValue).appendingPathComponent(screen) }
        var testDescription: String { name }

        func url(_ file: String) -> URL { directory.appendingPathComponent(file) }
        func data(_ file: String) throws -> Data { try Data(contentsOf: url(file)) }
    }

    /// Every screen directory, sorted by platform then screen.
    static func all() -> [Golden] {
        DevicePlatform.allCases.flatMap { platform -> [Golden] in
            let directory = root.appendingPathComponent(platform.rawValue)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.sorted().compactMap { name in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
                return isDirectory.boolValue ? Golden(platform: platform, screen: name) : nil
            }
        }
    }

    /// Every file under `trees/`, for the leak check.
    static func allFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }
    }

    /// The tree the current mapping makes of a raw capture, as describe-ui would print it.
    static func tree(from capture: RawTreeCapture) throws -> UITree {
        let roots: [UINode]
        switch capture.platform {
        case .ios:
            roots = try IOSAccessibilityMapping.roots(fromJSON: capture.source)
        case .android:
            let dump = try JSONDecoder().decode(HelperDump.self, from: capture.source)
            let scale = AndroidDisplayGeometry(display: dump.display)?.scale ?? (capture.screen?.scale ?? 1)
            roots = HelperTreeMapping.roots(from: dump, scale: scale, pid: 0).roots
        }
        return UITree(platform: capture.platform, device: placeholder(for: capture.platform), screen: capture.screen, roots: roots)
    }

    static func tree(of golden: Golden) throws -> UITree {
        try tree(from: try RawTreeCapture(jsonData: try golden.data(rawFile)))
    }

    static func renderings(of tree: UITree) -> [String: Data] {
        [
            jsonFile: tree.jsonData(),
            summaryFile: UITreeRenderer.render(tree, .summary),
            textFile: UITreeRenderer.render(tree, textOptions),
        ]
    }

    /// The raw capture as compact JSON with sorted keys, so it stays small and diffs stay stable.
    static func rawData(_ capture: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: capture, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    /// Writes the scrubbed raw capture and the three files derived from it.
    static func write(_ capture: [String: Any], to golden: Golden) throws {
        try FileManager.default.createDirectory(at: golden.directory, withIntermediateDirectories: true)
        try rawData(capture).write(to: golden.url(rawFile))
        try rerender(golden)
    }

    /// Rewrites the committed raw capture in the compact format and re-renders the derived files from it, offline.
    static func rerender(_ golden: Golden) throws {
        try rawData(try JSONSerialization.jsonObject(with: golden.data(rawFile))).write(to: golden.url(rawFile))
        for (file, data) in renderings(of: try tree(of: golden)) {
            try data.write(to: golden.url(file))
        }
    }

    // MARK: Budgets

    struct Budget: Equatable {
        var summary: Int
        var text: Int
    }

    static func budgets() throws -> [String: Budget] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: budgetsURL)) as? [String: Any]
        let entries = object?["budgets"] as? [String: [String: Int]] ?? [:]
        return entries.compactMapValues { entry in
            guard let summary = entry["summary"], let text = entry["text"] else { return nil }
            return Budget(summary: summary, text: text)
        }
    }

    /// The actual size rounded up to the next 64 bytes.
    static func budget(for size: Int) -> Int {
        (size / 64 + 1) * 64
    }

    /// Writes budgets for every golden: a new golden gets one, an existing budget only goes down.
    static func writeBudgets() throws {
        var budgets = (try? self.budgets()) ?? [:]
        let names = Set(all().map(\.name))
        budgets = budgets.filter { names.contains($0.key) }
        for golden in all() {
            let renderings = renderings(of: try tree(of: golden))
            let fresh = Budget(summary: budget(for: renderings[summaryFile]!.count), text: budget(for: renderings[textFile]!.count))
            let current = budgets[golden.name] ?? fresh
            budgets[golden.name] = Budget(summary: min(current.summary, fresh.summary), text: min(current.text, fresh.text))
        }
        var lines = ["{", "  \"version\": 1,", "  \"budgets\": {"]
        let sorted = budgets.keys.sorted()
        for (index, name) in sorted.enumerated() {
            let budget = budgets[name]!
            lines.append("    \"\(name)\": { \"summary\": \(budget.summary), \"text\": \(budget.text) }" + (index == sorted.count - 1 ? "" : ","))
        }
        lines += ["  }", "}", ""]
        try Data(lines.joined(separator: "\n").utf8).write(to: budgetsURL)
    }
}

/// Removes device and host identity from a raw capture, and refuses a secure field with a readable value.
enum TreeGoldenScrubber {
    static let zeroUUID = "00000000-0000-0000-0000-000000000000"
    static let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#

    struct SecureValueFound: Error, CustomStringConvertible {
        let description: String
    }

    static func scrub(_ value: Any, platform: DevicePlatform) throws -> Any {
        switch value {
        case let object as [String: Any]:
            try refuseReadableSecureValue(object, platform: platform)
            var scrubbed: [String: Any] = [:]
            for (key, child) in object {
                scrubbed[key] = platform == .ios && key == "pid" && child is NSNumber ? 1000 : try scrub(child, platform: platform)
            }
            return scrubbed
        case let array as [Any]:
            return try array.map { try scrub($0, platform: platform) }
        case let string as String:
            return scrub(string)
        default:
            return value
        }
    }

    static func scrub(_ text: String) -> String {
        var text = text.replacingOccurrences(of: uuidPattern, with: zeroUUID, options: .regularExpression)
        text = text.replacingOccurrences(of: #"emulator-\d+"#, with: TreeGoldens.placeholder(for: .android), options: .regularExpression)
        text = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let user = NSUserName()
        if user.count >= 3 {
            text = text.replacingOccurrences(of: user, with: "<user>")
        }
        return text
    }

    /// The raw capture predates redaction, so a secure field must already read empty or as bullets.
    private static func refuseReadableSecureValue(_ object: [String: Any], platform: DevicePlatform) throws {
        let secure: Bool
        let value: String?
        switch platform {
        case .ios:
            secure = object["type"] as? String == "SecureTextField" || object["subrole"] as? String == "AXSecureTextField"
                || object["role_description"] as? String == "secure text field"
            value = object["AXValue"] as? String
        case .android:
            secure = object["password"] as? Bool == true
            value = object["text"] as? String
        }
        guard secure, let value, !TreeGoldenLeaks.isMasked(value) else { return }
        throw SecureValueFound(description: "a secure field reads \(value.count) readable characters; capture refused")
    }
}

/// What must never appear in a committed tree golden.
enum TreeGoldenLeaks {
    static func isMasked(_ value: String) -> Bool {
        value.allSatisfy { $0 == SecureText.bullet }
    }

    static func findings(in text: String) -> [String] {
        var findings: [String] = []
        let patterns: [(String, String)] = [
            (TreeGoldenScrubber.uuidPattern, "a device UDID"),
            (#"emulator-\d+"#, "an emulator serial"),
            (#"/Users/|/home/"#, "a home path"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "an email address"),
            (#"\blocalhost\b|\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, "a host address"),
        ]
        for (pattern, name) in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let found = String(text[Range(match.range, in: text)!])
                if found != TreeGoldenScrubber.zeroUUID {
                    findings.append("\(name) (\(found))")
                }
            }
        }
        let user = NSUserName()
        if user.count >= 3, text.contains(user) {
            findings.append("the user name")
        }
        return findings
    }
}
