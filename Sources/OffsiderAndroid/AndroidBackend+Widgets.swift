import Foundation
import OffsiderCore

extension AndroidBackend: WidgetCapturing {
    public func widgets(of app: String, on id: DeviceID) async throws -> [HomeWidget] {
        try await prepare()
        let serial = id.rawValue
        let home = try await requireHomeInFront(on: id)
        let tree = try await readTree(id, point: nil, recording: false)
        let placed = try await requireClient().shell(AndroidWidgets.placedScript, on: serial, timeout: .seconds(5), label: "dumpsys appwidget")
        let bare = AndroidWidgets.hosts(in: tree).contains { $0.children.isEmpty }
        let everyView = bare ? try await readTree(id, point: nil, everyView: true) : nil
        return try AndroidWidgets.shown(of: app, in: tree, everyView: everyView, home: home, placed: AndroidWidgets.placed(in: placed.stdoutText), on: serial)
    }

    public func widgetMaskTree(on id: DeviceID) async throws -> UITree {
        try await readTree(id, point: nil, everyView: true)
    }

    public func widgetFullScreenPNG(on id: DeviceID) async throws -> Data {
        try await prepare()
        return try await host.timing.measure(.capture) { try await capturePNG(id.rawValue) }
    }

    /// The launcher Android would start for HOME, once it is what is in front.
    private func requireHomeInFront(on id: DeviceID) async throws -> String {
        let serial = id.rawValue
        let front = try await foreground(on: id)
        let package = { (component: String?) in component.flatMap { $0.split(separator: "/").first.map(String.init) } }
        guard let top = package(front.top) else { throw AndroidError.foregroundUnknown(serial) }
        guard let home = package(front.home), home != AndroidWindowFocus.systemOwner else {
            throw AndroidError.widgetNotShown("\(serial) has no default home screen app, so Offsider cannot tell which app holds the widget and captured nothing. Can you choose one on \(serial)?")
        }
        guard top == home else {
            throw AndroidError.widgetNotShown(
                "\(top) is in front on \(serial), not the home screen, so Offsider captured nothing. Run `offsider button home --device \(serial)`, then retry.",
                hint: "offsider button home --device \(serial)"
            )
        }
        return home
    }
}
