import Foundation
import OffsiderCore

/// Who placed which widget, from `dumpsys appwidget`, and which of the launcher's nodes are one app's.
enum AndroidWidgets {
    /// Every widget's host line and provider line, in pairs; nothing else in the dump is read.
    static let placedScript = "dumpsys appwidget | grep -E '^ *(host|provider)='"

    struct Placed: Equatable, Sendable {
        let host: String
        let provider: String
    }

    /// `host=HostId{..., pkg:<launcher>}` then `provider=ProviderId{..., cmp:ComponentInfo{<package>/<class>}}`; a host with no provider is left out.
    static func placed(in output: String) -> [Placed] {
        var host: String?
        var rows: [Placed] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("host=") {
                host = line.range(of: "pkg:").map { String(line[$0.upperBound...].prefix { $0 != "}" && $0 != "," }) }
            } else if line.hasPrefix("provider="), let owner = host {
                if let start = line.range(of: "cmp:ComponentInfo{"), let package = line[start.upperBound...].split(separator: "/").first {
                    rows.append(Placed(host: owner, provider: String(package)))
                }
                host = nil
            }
        }
        return rows
    }

    /// The launcher's widget hosts, by class: Android's `AppWidgetHostView` or a launcher's own subclass of it.
    static func hosts(in tree: UITree) -> [UINode] {
        tree.roots.flatMap { $0.flattened() }.filter { node in
            guard case .android(let native) = node.native else { return false }
            return native.className?.hasSuffix("AppWidgetHostView") == true
        }
    }

    /// A widget's views name the app that drew them, so a host is `app`'s only when it has views and all of them do.
    static func isOwned(_ host: UINode, by app: String) -> Bool {
        let packages = host.flattened().dropFirst().compactMap { node -> String? in
            guard case .android(let native) = node.native else { return nil }
            return native.package
        }
        return !packages.isEmpty && packages.allSatisfy { $0 == app }
    }

    /// `app`'s widgets in reading order, when only each widget would show in its frame. Hosts come only from `tree`, which hides what a folder or Recents covers; `everyView` holds an image-only widget's views.
    static func shown(of app: String, in tree: UITree, everyView: UITree? = nil, home: String, placed: [Placed], on serial: String) throws -> [HomeWidget] {
        guard let windows = tree.windows, !windows.isEmpty else {
            throw AndroidError.widgetNotShown(
                "Offsider needs its helper to prove nothing covers a widget, and it is not running on \(serial), so it captured nothing. Run `offsider doctor --device \(serial)`.",
                hint: "offsider doctor --device \(serial)"
            )
        }
        if let over = AndroidBackend.activeWindowPackages(tree).first(where: { $0 != home }) {
            throw AndroidError.widgetNotShown("\(over) is over the home screen on \(serial), so Offsider captured nothing. Close it, then retry.")
        }
        guard let launcher = windows.first(where: { $0.active && $0.package == home }) ?? windows.first(where: { $0.focused && $0.package == home }) else {
            throw AndroidError.widgetNotShown("The home screen has no active window on \(serial), so Offsider captured nothing. Unlock the device, then retry.")
        }
        guard placed.contains(where: { $0.host == home && $0.provider == app }) else {
            throw AndroidError.widgetNotShown("\(app) has no widget on the home screen of \(serial), so Offsider captured nothing. Can you add one on \(serial)?")
        }
        let hosts = hosts(in: tree)
        let detailed = everyView.map(Self.hosts(in:)) ?? []
        let owned = hosts.filter { host in isOwned(detailed.first { $0.frame == host.frame } ?? host, by: app) }
        let sized = owned.compactMap { host -> (UINode, UIFrame)? in
            guard let frame = host.frame, frame.width > 0, frame.height > 0 else { return nil }
            return (host, frame)
        }
        guard !sized.isEmpty else {
            throw AndroidError.widgetNotShown("\(app)'s widget is not on this page of the home screen on \(serial), so Offsider captured nothing. Can you swipe to it on \(serial)?")
        }
        for (host, frame) in sized {
            let beside = hosts.contains { !$0.isSameElement(as: host) && overlaps($0.frame, frame) }
            let above = windows.contains { $0.package != home && $0.layer > launcher.layer && overlaps($0.bounds, frame) }
            if beside || above {
                throw AndroidError.widgetNotShown("Something else overlaps \(app)'s widget on \(serial), and it would show in the image, so Offsider captured nothing. Close it, then retry.")
            }
        }
        return sized.map { HomeWidget(frame: $0.1, label: $0.0.label.flatMap(AndroidWindowFocus.shown)) }.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
    }

    private static func overlaps(_ a: UIFrame?, _ b: UIFrame) -> Bool {
        a?.intersection(b).map { $0.width > 0 && $0.height > 0 } ?? false
    }
}
