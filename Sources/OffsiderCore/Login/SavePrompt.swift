import Foundation

/// A system prompt that offers to save the password after a sign-in. Offsider only ever declines it, and only where no person's saved passwords are at stake.
public struct SavePrompt: Equatable, Sendable {
    /// False for a system window Offsider could not tell to be a save-password prompt.
    public var savesPassword: Bool
    /// The prompt's own title, such as `Save Password?`; nil when nothing on it could be read.
    public var title: String?
    /// The decline control's label, such as `Not Now`; nil when none was found.
    public var declineLabel: String?
    /// The middle of the decline control; nil when none was found.
    public var decline: UIPoint?

    public init(savesPassword: Bool = true, title: String?, declineLabel: String? = nil, decline: UIPoint? = nil) {
        self.savesPassword = savesPassword
        self.title = title
        self.declineLabel = declineLabel
        self.decline = decline
    }

    /// `the "Save Password?" prompt`, for a sentence.
    public var summary: String {
        if let title { return "the \(TerminalText.quoted(SelectorText.truncated(title))) prompt" }
        return savesPassword ? "the system's save-password prompt" : "a system prompt"
    }

    /// The request for the person holding the device.
    public var ask: String {
        savesPassword
            ? "Can you tap \(declineLabel ?? "Not Now") on \(summary) on \(PersonAsk.devicePlaceholder)?"
            : "Can you answer \(summary) on \(PersonAsk.devicePlaceholder)?"
    }
}

/// What `login` did about a save-password prompt after submit.
public enum SavePromptOutcome: String, Equatable, Sendable {
    /// Offsider tapped the prompt's decline control and the prompt went.
    case declined
    /// A person closed it while `login` watched.
    case closed
    /// Still up when `login` ended.
    case open
}

/// Finds a save-password prompt and its decline control. Nothing here names a Save, Update or Allow control.
public enum SavePrompts {
    /// The only labels Offsider taps: each closes the prompt and changes nothing that lasts.
    static let declineLabels: Set<String> = ["not now", "no thanks"]
    static let iosTitles: Set<String> = ["save password?", "update password?"]
    static let androidDeclineID = "android:id/autofill_save_no"
    static let androidSaveID = "android:id/autofill_save_yes"
    static let androidTitleID = "android:id/autofill_save_title"

    /// True for the title iOS gives its own prompt.
    public static func isIOSTitle(_ title: String?) -> Bool {
        title.map { iosTitles.contains(plain($0)) } ?? false
    }

    /// True for a button whose whole label is a decline.
    public static func isDecline(_ node: UINode) -> Bool {
        node.role == .button && node.enabled != false && node.normalizedLabel.map { declineLabels.contains(plain($0)) } == true
    }

    /// iOS, where the tree itself lists the prompt, as a runner's tree can; a simulator's prompt needs point reads instead.
    public static func ios(in tree: UITree) -> SavePrompt? {
        guard tree.platform == .ios else { return nil }
        let nodes = tree.roots.flatMap { $0.flattened() }
        guard let title = nodes.first(where: { ($0.role == .text || $0.role == .header) && isIOSTitle($0.normalizedLabel) })?.normalizedLabel else { return nil }
        return prompt(title: title, decline: nodes.first(where: isDecline))
    }

    /// Android, in a tree that lists every window: the system's own save dialog by its ids, or a window from another package holding a password save offer, a Save button and a decline.
    public static func android(in tree: UITree, app: String) -> SavePrompt? {
        guard tree.platform == .android else { return nil }
        for root in tree.roots {
            let all = root.flattened()
            if all.contains(where: { resourceID(of: $0) == androidSaveID }), let no = all.first(where: { resourceID(of: $0) == androidDeclineID }) {
                let title = all.first { resourceID(of: $0) == androidTitleID }?.normalizedLabel
                return prompt(title: title, decline: declines(no) ? no : nil)
            }
            // A node that names no package could be the app's own, so only another package's window counts.
            let nodes = all.filter { package(of: $0).map { $0 != app } ?? false }
            let offer = nodes.first { node in
                guard node.role == .text || node.role == .header, let text = node.normalizedLabel.map(plain) else { return false }
                return text.contains("save") && text.contains("password")
            }
            let saves = nodes.contains { $0.role == .button && $0.normalizedLabel.map { plain($0).hasPrefix("save") } == true }
            if let offer, saves, let no = nodes.first(where: isDecline) {
                return prompt(title: offer.normalizedLabel, decline: no)
            }
        }
        return nil
    }

    /// Where a simulator's prompt is read for its decline control: rows below its title, each read at its left, its right and its middle, as the buttons sit side by side on a card or stacked on a sheet.
    public static func probeRows(below title: UIFrame, in viewport: UIFrame) -> [[UIPoint]] {
        let xs = [title.x + title.width * 0.15, title.x + title.width * 0.85, title.x + title.width / 2]
        let end = min(viewport.y + viewport.height - 8, title.y + title.height + probeDepth)
        return stride(from: title.y + title.height + probeStep, to: end, by: probeStep).map { y in xs.map { UIPoint(x: $0, y: y) } }
    }

    /// Less than a button's height, so no row of buttons falls between two reads.
    static let probeStep: Double = 30
    static let probeDepth: Double = 300

    private static func prompt(title: String?, decline: UINode?) -> SavePrompt {
        SavePrompt(title: title, declineLabel: decline?.normalizedLabel, decline: decline?.frame?.center)
    }

    private static func declines(_ node: UINode) -> Bool {
        node.enabled != false && node.normalizedLabel.map { declineLabels.contains(plain($0)) } == true
    }

    private static func package(of node: UINode) -> String? {
        guard case .android(let attributes) = node.native else { return nil }
        return attributes.package
    }

    private static func resourceID(of node: UINode) -> String? {
        guard case .android(let attributes) = node.native else { return nil }
        return attributes.resourceId
    }

    private static func plain(_ text: String) -> String {
        text.lowercased().split { $0.isWhitespace }.joined(separator: " ")
    }
}
