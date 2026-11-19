import Foundation

/// A SpringBoard alert over one app, as an iOS simulator's tree lists it: the alert, and beneath it the app's switcher card.
public enum IOSPermissionAlert {
    /// The grants `accept` may pick when the alert carries no ids, narrowest lasting one first.
    static let acceptLabels = ["allow while using app", "allow"]
    static let denyLabels = ["don't allow"]
    static let cardPrefix = "card:"
    static let cardSceneMark = ":sceneID:"

    /// The alert in SpringBoard's `tree` when it is for `app`; throws `AppPromptRefusal` naming what is there otherwise.
    public static func read(_ tree: UITree, app: String) throws -> AppPrompt {
        let cards = self.cards(in: tree)
        guard let alert = alertNode(in: tree), let title = alert.normalizedLabel, let frame = alert.frame else {
            // An alert this iOS lists in a shape Offsider does not know is still an alert: stop, never report an empty screen.
            if let viewport = tree.viewport, SystemPrompt.alert(in: tree, covers: viewport.center), let unknown = SystemPrompt.alert(in: tree) {
                throw AppPromptRefusal.notPermission(what: "the system alert \(TerminalText.quoted(SelectorText.truncated(unknown.title, limit: 120))), in a layout Offsider does not know")
            }
            throw AppPromptRefusal.notShown(front: cards.count == 1 ? cards[0].bundle : nil)
        }
        let shown = TerminalText.quoted(SelectorText.truncated(title, limit: 120))
        guard let card = cards.first, cards.count == 1 else {
            throw AppPromptRefusal.otherApp(requester: nil, why: cards.isEmpty ? "no app is beneath the alert \(shown)" : "more than one app is beneath the alert \(shown)")
        }
        guard card.bundle == app else {
            throw AppPromptRefusal.otherApp(requester: card.bundle, why: "the alert \(shown) is over \(card.bundle)")
        }
        guard let named = firstQuotedName(in: title) else {
            throw AppPromptRefusal.notPermission(what: "the system alert \(shown), which names no app")
        }
        guard let name = card.name, named == name else {
            throw AppPromptRefusal.otherApp(requester: nil, why: "the alert \(shown) names another app first")
        }
        let found = buttons(in: alert)
        let service = serviceID(of: alert)
        guard service != nil || found.count >= 2 else {
            throw AppPromptRefusal.notPermission(what: "the system alert \(shown), which asks nothing")
        }
        let accept: Int?
        let deny: Int?
        if service != nil {
            accept = found.firstIndex { $0.id?.hasSuffix("-allow-button") == true }
            deny = found.firstIndex { $0.id?.hasSuffix("-deny-button") == true }
        } else {
            let folded = found.map { SelectorText.folded($0.label).lowercased() }
            accept = acceptLabels.lazy.compactMap { folded.firstIndex(of: $0) }.first
            deny = denyLabels.lazy.compactMap { folded.firstIndex(of: $0) }.first
        }
        let buttons = found.enumerated().map { index, button in
            AppPrompt.Button(label: button.label, role: index == accept ? .accept : index == deny ? .deny : .other, frame: button.frame)
        }
        let message = alert.flattened().dropFirst().first { $0.role == .text && $0.normalizedLabel != nil && $0.normalizedLabel != title }?.normalizedLabel
        return AppPrompt(app: app, title: title, message: message, buttons: buttons, frame: frame, source: "SpringBoard", token: "\(service ?? "alert") \(title)")
    }

    /// The topmost sheet or alert that holds a button and covers the middle of the screen without filling it.
    static func alertNode(in tree: UITree) -> UINode? {
        guard tree.platform == .ios, let viewport = tree.viewport else { return nil }
        return tree.roots.flatMap { $0.flattened() }.last { node in
            guard case .ios(let native) = node.native, let type = native.type, type == "Sheet" || type == "Alert",
                  node.normalizedLabel != nil, let frame = node.frame, frame.contains(viewport.center),
                  frame.width < viewport.width - 1 || frame.height < viewport.height - 1 else { return false }
            return node.flattened().contains { $0.role == .button }
        }
    }

    /// The apps SpringBoard lists a scene for: `card:<bundle id>:sceneID:…`, labelled with the app's name.
    static func cards(in tree: UITree) -> [(bundle: String, name: String?)] {
        var seen: [(bundle: String, name: String?)] = []
        for node in tree.roots.flatMap({ $0.flattened() }) {
            guard let id = node.normalizedID, id.hasPrefix(cardPrefix), let mark = id.range(of: cardSceneMark) else { continue }
            let bundle = String(id[id.index(id.startIndex, offsetBy: cardPrefix.count)..<mark.lowerBound])
            guard !bundle.isEmpty, !seen.contains(where: { $0.bundle == bundle }) else { continue }
            seen.append((bundle, node.normalizedLabel))
        }
        return seen
    }

    /// `kTCCServiceCamera` of the id `kTCCServiceCamera-alert`: set only on a privacy prompt, whatever the language.
    static func serviceID(of alert: UINode) -> String? {
        guard let id = alert.normalizedID, id.hasPrefix("kTCCService"), id.hasSuffix("-alert") else { return nil }
        return id.split(separator: "-").first.map(String.init)
    }

    /// The alert's buttons, each once: iOS lists a button inside itself.
    static func buttons(in alert: UINode) -> [(label: String, id: String?, frame: UIFrame)] {
        var found: [(label: String, id: String?, frame: UIFrame)] = []
        for node in alert.flattened() where node.role == .button {
            guard let label = node.normalizedLabel, let frame = node.frame, frame.width > 0, frame.height > 0,
                  !found.contains(where: { $0.label == label && $0.frame == frame }) else { continue }
            found.append((label, node.normalizedID, frame))
        }
        return found
    }

    private static let quotes: [Character: Character] = ["“": "”", "«": "»", "„": "“", "‘": "’", "「": "」", "『": "』", "\"": "\""]

    /// `Example` of `Allow “Example” to use your location?`: the first name the title quotes.
    static func firstQuotedName(in title: String) -> String? {
        guard let open = title.firstIndex(where: { quotes[$0] != nil }), let close = quotes[title[open]] else { return nil }
        let rest = title[title.index(after: open)...]
        guard let end = rest.firstIndex(of: close) else { return nil }
        let name = rest[..<end].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
