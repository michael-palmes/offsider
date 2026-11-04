import Foundation

/// Keyboard text beside the keys (suggestions, a clipboard chip, clipboard history), hidden where Android trees are read and painted in screenshots.
public enum KeyboardText {
    /// What a hidden element's label, value and text read.
    public static let marker = LogRedactor.marker

    /// Gboard's key ids; its other ids are obfuscated.
    static let gboardKeyID = ":id/key_pos_"

    /// View classes whose children scroll, as suggestion strips and clipboard history do and rows of keys do not.
    static let scrollingClasses: Set<String> = [
        "ScrollView", "HorizontalScrollView", "NestedScrollView", "RecyclerView", "ListView", "GridView", "ViewPager", "ViewPager2",
    ]

    /// A keyboard window's tree with every element that is not a key reading `marker` for its label, value and text; the root keeps its window's title.
    public static func hiding(_ root: UINode) -> UINode {
        var copy = root
        for index in copy.children.indices {
            copy.children[index] = hide(copy.children[index], scrolls: scrolls(root), keyName: nil).node
        }
        return copy
    }

    /// The node, its text hidden unless a key, and whether it holds view text; `keyName` is the parent's description when the parent may be a key.
    private static func hide(_ node: UINode, scrolls inherited: Bool, keyName: String?) -> (node: UINode, holdsText: Bool) {
        let scrolling = inherited || scrolls(node)
        let own = holdsText(node)
        let name = !own && !scrolling ? description(of: node) : nil
        var copy = node
        var textBelow = false
        for index in copy.children.indices {
            let hidden = hide(copy.children[index], scrolls: scrolling, keyName: name)
            copy.children[index] = hidden.node
            textBelow = textBelow || hidden.holdsText
        }
        let glyph = own && !scrolling && node.children.isEmpty && isGlyph(node, of: keyName)
        if glyph { return (copy, false) }
        if !isKey(node, holdsText: own, textBelow: textBelow, scrolling: scrolling) {
            hideText(&copy)
        }
        return (copy, own || textBelow)
    }

    /// A key holds no view text, nor does anything inside it, and sits in nothing that scrolls, unless Gboard's key id names it.
    static func isKey(_ node: UINode, holdsText: Bool, textBelow: Bool, scrolling: Bool) -> Bool {
        guard !holdsText, !textBelow else { return false }
        return !scrolling || node.normalizedID?.contains(gboardKeyID) == true
    }

    /// What a key draws in a text view, as Gboard's number row and Samsung Keyboard's letters do: one character, or the key's own name.
    static func isGlyph(_ node: UINode, of keyName: String?) -> Bool {
        guard case .android(let attributes) = node.native, let text = attributes.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return text.count == 1 || (keyName != nil && text == keyName)
    }

    private static func description(of node: UINode) -> String? {
        guard case .android(let attributes) = node.native else { return nil }
        let trimmed = attributes.contentDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Android's own text, or a value that is screen text rather than a toggle's state.
    static func holdsText(_ node: UINode) -> Bool {
        if case .android(let attributes) = node.native, attributes.text?.contains(where: { !$0.isWhitespace }) == true { return true }
        return node.role.valueIsScreenText && node.normalizedValue != nil
    }

    static func scrolls(_ node: UINode) -> Bool {
        if node.role == .scrollView || node.role == .list { return true }
        guard case .android(let attributes) = node.native, let name = attributes.className?.split(separator: ".").last else { return false }
        return scrollingClasses.contains(String(name))
    }

    /// Every attribute that can carry text, replaced by `marker` where it is not empty.
    static func hideText(_ node: inout UINode) {
        let hide = { (text: String) in text.isEmpty ? text : marker }
        node.label = node.label.map(hide)
        node.value = node.value.map(hide)
        node.native.redactText(hide)
    }

    /// Whether `hideText` replaced something on `node`.
    static func isHidden(_ node: UINode) -> Bool {
        if node.label == marker || node.value == marker { return true }
        guard case .android(let attributes) = node.native else { return false }
        return attributes.text == marker || attributes.contentDescription == marker
    }

    /// The elements of `roots`' keyboards whose text is hidden, for painting.
    public static func hiddenElements(in roots: [UINode]) -> [UINode] {
        roots.filter { $0.role == .keyboard }.flatMap { root in root.children.flatMap { $0.flattened() } }.filter(isHidden)
    }

    /// How many hidden elements the keyboards show: the innermost, so a chip and the text inside it count once.
    public static func hiddenCount(in roots: [UINode]) -> Int {
        func count(_ node: UINode) -> (total: Int, hiddenInside: Bool) {
            var total = 0
            var inside = false
            for child in node.children {
                let below = count(child)
                total += below.total
                inside = inside || below.hiddenInside
            }
            let hidden = isHidden(node)
            return (total + (hidden && !inside ? 1 : 0), inside || hidden)
        }
        return roots.filter { $0.role == .keyboard }.reduce(0) { sum, root in sum + root.children.reduce(0) { $0 + count($1).total } }
    }

    /// Android's keyboard windows the tree has no keys for: their whole bounds are painted, as nothing tells their keys from their text.
    public static func unreadWindows(in tree: UITree) -> [UIFrame] {
        guard tree.platform == .android, let windows = tree.windows, !tree.roots.contains(where: { $0.role == .keyboard && !$0.children.isEmpty }) else { return [] }
        return windows.filter { $0.kind == "inputMethod" }.compactMap(\.bounds).filter { $0.width > 0 && $0.height > 0 }
    }
}

/// Android's copy preview: SystemUI's overlay of what was just copied, on an emulator whatever was copied on the Mac.
public enum CopyPreview {
    public static let package = "com.android.systemui"
    /// Its root view's id, and the prefix of the ids beside it.
    public static let idPrefix = "com.android.systemui:id/clipboard"

    /// True when `root`, a window's tree, is the copy preview.
    public static func isPreview(_ root: UINode) -> Bool {
        guard case .android(let attributes) = root.native, attributes.package == package else { return false }
        return root.contains { $0.normalizedID?.hasPrefix(idPrefix) == true }
    }

    /// The copy preview's tree with every text hidden; the root keeps its window's title.
    public static func hiding(_ root: UINode) -> UINode {
        var copy = root
        copy.children = root.children.map(hidingAll)
        return copy
    }

    private static func hidingAll(_ node: UINode) -> UINode {
        var copy = node
        KeyboardText.hideText(&copy)
        copy.children = node.children.map(hidingAll)
        return copy
    }

    /// System windows that may be the copy preview: untitled, unread, with bounds, and not a bar along an edge, which the status and navigation bars are.
    public static func candidates(in windows: [UIWindowInfo]) -> [UIWindowInfo] {
        guard let screen = UIFrame.union(of: windows.compactMap(\.bounds).filter { $0.width > 0 && $0.height > 0 }) else { return [] }
        return windows.filter { window in
            guard window.kind == "system", window.title?.isEmpty ?? true, window.package == nil, !window.copyPreview,
                  let bounds = window.bounds, bounds.width > 0, bounds.height > 0 else { return false }
            return !isEdgeBar(bounds, in: screen)
        }
    }

    /// At least 90 % of the screen across one way and at most a quarter of it the other, touching an edge.
    static func isEdgeBar(_ bounds: UIFrame, in screen: UIFrame) -> Bool {
        let tolerance = 1.0
        let wide = bounds.width >= 0.9 * screen.width && bounds.height <= screen.height / 4
            && (bounds.y <= screen.y + tolerance || bounds.y + bounds.height >= screen.y + screen.height - tolerance)
        let tall = bounds.height >= 0.9 * screen.height && bounds.width <= screen.width / 4
            && (bounds.x <= screen.x + tolerance || bounds.x + bounds.width >= screen.x + screen.width - tolerance)
        return wide || tall
    }

    /// Where the copy preview shows: the windows a read marked, and the app root when the preview is the window in front.
    public static func frames(in tree: UITree) -> [UIFrame] {
        let windows = (tree.windows ?? []).filter(\.copyPreview).compactMap(\.bounds)
        let roots = tree.roots.filter { $0.role == .application && isPreview($0) }.compactMap(\.frame)
        return windows + roots
    }

    /// How many copy previews the tree's roots show.
    public static func shownCount(in roots: [UINode]) -> Int {
        roots.count { $0.role == .application && isPreview($0) }
    }
}
