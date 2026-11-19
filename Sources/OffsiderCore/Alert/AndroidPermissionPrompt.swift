import Foundation

/// Android's runtime permission dialog, read by its buttons' resource ids so a device language cannot swap grant and refusal.
public enum AndroidPermissionPrompt {
    /// The grants `accept` may pick, narrowest lasting one first: never "all the time", a one-time grant or a photo picker.
    static let acceptEntries = ["permission_allow_foreground_only_button", "permission_allow_button"]
    /// The refusals `deny` may pick: never "don't ask again".
    static let denyEntries = ["permission_deny_button", "permission_no_upgrade_button"]
    static let messageEntries = ["permission_message", "detail_message"]

    /// The dialog in `tree`, whose every root belongs to a permission controller; nil when it is not one or shows no button.
    public static func read(_ tree: UITree, app: String, token: String) -> AppPrompt? {
        guard tree.platform == .android else { return nil }
        guard isDialog(tree), let source = tree.roots.first.flatMap(package) else { return nil }
        let nodes = tree.roots.flatMap { $0.flattened() }
        let shown = nodes.filter { node in
            guard let frame = node.frame, frame.width > 0, frame.height > 0 else { return false }
            return tree.viewport.map(frame.isVisible(in:)) ?? true
        }
        let found = shown.compactMap { node -> (entry: String, label: String, frame: UIFrame)? in
            guard node.role == .button, node.enabled != false, let entry = entry(of: node), entry.hasPrefix("permission_"), entry.hasSuffix("_button"),
                  let label = node.normalizedLabel, let frame = node.frame else { return nil }
            return (entry, label, frame)
        }
        guard !found.isEmpty else { return nil }
        let accept = acceptEntries.first { entry in found.contains { $0.entry == entry } }
        let deny = denyEntries.first { entry in found.contains { $0.entry == entry } }
        let buttons = found.map { button in
            AppPrompt.Button(label: button.label, role: button.entry == accept ? .accept : button.entry == deny ? .deny : .other, frame: button.frame)
        }
        let texts = messageEntries.compactMap { wanted in shown.first { entry(of: $0) == wanted }?.normalizedLabel }
        guard let title = texts.first ?? tree.roots.first?.normalizedLabel else { return nil }
        let box = tree.roots.first?.frame ?? UIFrame.union(of: found.map(\.frame)) ?? found[0].frame
        return AppPrompt(app: app, title: title, message: texts.count > 1 ? texts[1] : nil, buttons: buttons, frame: box, source: source, token: token)
    }

    /// True when every root of `tree` belongs to one permission controller, whatever its layout.
    public static func isDialog(_ tree: UITree) -> Bool {
        let packages = tree.roots.map(package)
        guard let first = packages.first ?? nil, packages.allSatisfy({ $0 == first }) else { return false }
        return SystemAppDenyList.isPermissionDialog(first, platform: .android)
    }

    private static func package(of node: UINode) -> String? {
        guard case .android(let native) = node.native, let package = native.package, !package.isEmpty else { return nil }
        return package
    }

    /// `permission_deny_button` of `com.android.permissioncontroller:id/permission_deny_button`.
    static func entry(of node: UINode) -> String? {
        guard case .android(let native) = node.native, let id = native.resourceId ?? node.normalizedID else { return nil }
        return id.split(separator: "/").last.map(String.init)
    }
}
