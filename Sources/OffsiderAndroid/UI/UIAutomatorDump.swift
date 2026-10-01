import Foundation

/// One `<node>` of a `uiautomator dump`, attributes verbatim.
struct RawAndroidNode: Equatable, Sendable {
    var attributes: [String: String]
    var children: [RawAndroidNode]

    init(attributes: [String: String], children: [RawAndroidNode] = []) {
        self.attributes = attributes
        self.children = children
    }

    subscript(_ name: String) -> String {
        attributes[name] ?? ""
    }

    func flag(_ name: String) -> Bool {
        attributes[name] == "true"
    }
}

struct UIAutomatorHierarchy: Equatable, Sendable {
    /// `<hierarchy rotation="N">`: the guest rotation when the dump ran.
    let rotation: Int?
    let nodes: [RawAndroidNode]
}

enum UIAutomatorDump {
    enum Outcome: Equatable, Sendable {
        case tree(String)
        case busy
        case idleTimeout
        case noWindow
        case failed(String)
    }

    /// Unique per process and call, so two Offsider runs never read each other's file.
    static func devicePath(pid: Int32, counter: Int) -> String {
        "/data/local/tmp/offsider-ui-\(pid)-\(counter).xml"
    }

    /// The device-side limit, under the host's 20 s, so a slow dump never outlives the command and holds UiAutomation.
    static let deviceTimeoutSeconds = 18

    /// Prints the XML on stdout and deletes the file. On failure uiautomator's output goes to stderr and the status is
    /// 4 for the device timeout, the signal status when uiautomator was killed, else 3.
    static func script(path: String) -> String {
        let file = AdbShellQuoting.quote(path)
        return "f=\(file); out=$(timeout \(deviceTimeoutSeconds) uiautomator dump --compressed \"$f\" 2>&1); rc=$?; "
            + "if [ -s \"$f\" ]; then cat \"$f\"; rm -f \"$f\"; else rm -f \"$f\"; echo \"$out\" >&2; "
            + "[ $rc -eq 124 ] && exit 4; [ $rc -ge 128 ] && exit $rc; exit 3; fi"
    }

    static func classify(_ result: AdbShellResult) -> Outcome {
        let stdout = result.stdoutText
        if result.status == 0, stdout.hasPrefix("<?xml") {
            return .tree(stdout)
        }
        let stderr = result.stderrText
        if stderr.contains("could not get idle state") {
            return .idleTimeout
        }
        if stderr.contains("null root node") {
            return .noWindow
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 4 {
            return .failed("no hierarchy within \(deviceTimeoutSeconds) s; the emulator may be overloaded")
        }
        if result.status == 137 || result.status == 134 || (result.status == 3 && trimmed.isEmpty) {
            return .busy
        }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init)
        return .failed(firstLine ?? "exit status \(result.status)")
    }

    struct ParseFailure: Error, Equatable {
        let detail: String
    }

    static func parse(_ xml: String) throws -> UIAutomatorHierarchy {
        let delegate = HierarchyBuilder()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        guard parser.parse(), let hierarchy = delegate.hierarchy else {
            throw ParseFailure(detail: parser.parserError?.localizedDescription ?? "no <hierarchy> element")
        }
        return hierarchy
    }
}

private final class HierarchyBuilder: NSObject, XMLParserDelegate {
    private var rotation: Int?
    private var sawHierarchy = false
    private var stack: [RawAndroidNode] = []
    private var roots: [RawAndroidNode] = []

    var hierarchy: UIAutomatorHierarchy? {
        sawHierarchy ? UIAutomatorHierarchy(rotation: rotation, nodes: roots) : nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "hierarchy":
            sawHierarchy = true
            rotation = attributes["rotation"].flatMap { Int($0) }
        case "node":
            stack.append(RawAndroidNode(attributes: attributes))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard elementName == "node", let node = stack.popLast() else { return }
        if stack.isEmpty {
            roots.append(node)
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }
}
