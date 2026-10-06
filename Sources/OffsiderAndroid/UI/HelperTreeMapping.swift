import Foundation
import OffsiderCore

/// A dump's nodes beside the references the helper needs to act on them, for one helper process and generation.
struct HelperTreeIndex: Equatable, Sendable {
    /// The helper process the generation belongs to.
    let pid: Int32
    let generation: Int
    /// Pre-order across the roots, in the order the roots are returned.
    let entries: [HelperTreeEntry]
}

struct HelperTreeEntry: Equatable, Sendable {
    let node: UINode
    let ref: HelperNodeRef
    let range: HelperRange?
}

struct HelperNodeRef: Equatable, Sendable {
    let generation: Int
    let index: Int
    let className: String?
    let resourceId: String?
}

/// Helper JSON to the `RawAndroidNode` shape `uiautomator` gives, so `AndroidTreeMapping` stays the one mapper.
enum HelperTreeMapping {
    /// `uiautomator` attribute names, booleans as "true" or "false", plus the helper's extra fields.
    static func rawNode(_ node: HelperNode) -> RawAndroidNode {
        var attributes: [String: String] = [
            "class": node.class ?? "",
            "package": node.package ?? "",
            "resource-id": node.resourceId ?? "",
            "text": node.text ?? "",
            "content-desc": node.contentDescription ?? "",
            "hint": node.hint ?? "",
            "bounds": bounds(node.bounds),
            "checkable": flag(node.checkable),
            "checked": flag(node.checked),
            "clickable": flag(node.clickable),
            "long-clickable": flag(node.longClickable),
            "enabled": flag(node.enabled),
            "focusable": flag(node.focusable),
            "focused": flag(node.focused),
            "scrollable": flag(node.scrollable),
            "selected": flag(node.selected),
            "editable": flag(node.editable),
            "password": flag(node.password),
            "visible-to-user": flag(node.visibleToUser),
        ]
        attributes["state-description"] = node.stateDescription
        attributes["role-description"] = node.roleDescription
        attributes["test-tag"] = node.testTag
        attributes["checked-state"] = node.checkedState
        if let range = node.rangeInfo {
            attributes["range-type"] = range.type
            attributes["range-min"] = number(range.min)
            attributes["range-max"] = number(range.max)
            attributes["range-current"] = number(range.current)
        }
        return RawAndroidNode(attributes: attributes, children: node.children.map(rawNode))
    }

    /// The window that becomes the `application` root: the active one, else the topmost application window.
    static func appWindow(in dump: HelperDump) -> HelperWindow? {
        let walked = dump.windows.filter { $0.root != nil && $0.type != "inputMethod" }
        return walked.first { $0.active }
            ?? walked.filter { $0.type == "application" }.max { $0.layer < $1.layer }
            ?? walked.first
    }

    /// Every listed window in dp, with the package of its root when the helper walked it.
    static func windows(from dump: HelperDump, scale: Double) -> [UIWindowInfo] {
        dump.windows.map { window in
            let bounds = window.bounds.count == 4 && scale > 0
                ? UIFrame(
                    x: Double(window.bounds[0]) / scale, y: Double(window.bounds[1]) / scale,
                    width: Double(window.bounds[2] - window.bounds[0]) / scale, height: Double(window.bounds[3] - window.bounds[1]) / scale
                )
                : nil
            return UIWindowInfo(
                id: window.id, kind: window.type, layer: window.layer, title: window.title,
                active: window.active, focused: window.focused, package: window.root?.package, bounds: bounds
            )
        }
    }

    /// The app window as `application`, then each keyboard as `keyboard`, both titled; bars are left out.
    static func roots(from dump: HelperDump, scale: Double, pid: Int32) -> (roots: [UINode], index: HelperTreeIndex) {
        guard let app = appWindow(in: dump), let appRoot = app.root else {
            return ([], HelperTreeIndex(pid: pid, generation: dump.generation, entries: []))
        }
        var trees: [(HelperNode, UINode)] = [
            (appRoot, AndroidTreeMapping.node(from: rawNode(appRoot), scale: scale, rootRole: .application, rootLabel: app.title)),
        ]
        for keyboard in dump.windows where keyboard.type == "inputMethod" {
            guard let root = keyboard.root else { continue }
            trees.append((root, AndroidTreeMapping.node(from: rawNode(root), scale: scale, rootRole: .keyboard, rootLabel: keyboard.title)))
        }
        var entries: [HelperTreeEntry] = []
        for (helperRoot, mappedRoot) in trees {
            index(helperRoot, mappedRoot, generation: dump.generation, into: &entries)
        }
        return (trees.map(\.1), HelperTreeIndex(pid: pid, generation: dump.generation, entries: entries))
    }

    private static func index(_ helper: HelperNode, _ mapped: UINode, generation: Int, into entries: inout [HelperTreeEntry]) {
        let ref = HelperNodeRef(generation: generation, index: helper.i, className: helper.class, resourceId: helper.resourceId)
        entries.append(HelperTreeEntry(node: mapped, ref: ref, range: helper.rangeInfo))
        for (child, mappedChild) in zip(helper.children, mapped.children) {
            index(child, mappedChild, generation: generation, into: &entries)
        }
    }

    private static func bounds(_ values: [Int]) -> String {
        guard values.count == 4 else { return "" }
        return "[\(values[0]),\(values[1])][\(values[2]),\(values[3])]"
    }

    private static func flag(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func number(_ value: Double) -> String? {
        value.isFinite ? String(value) : nil
    }
}
