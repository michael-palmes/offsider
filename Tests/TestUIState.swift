import Foundation

/// One node of the neutral describe-ui schema.
struct UIElement: Decodable {
    let role: String
    let id: String?
    let label: String?
    let value: String?
    let frame: Frame?
    let enabled: Bool?
    let state: State
    let native: Native
    let children: [UIElement]?

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct State: Decodable {
        let checked: Bool?
        let selected: Bool?
        let focused: Bool?
    }

    struct Native: Decodable {
        let type: String?
        let role: String?
        let subrole: String?
        let roleDescription: String?
        let title: String?
        let help: String?
        let customActions: [String]?
        let contentRequired: Bool?
        let pid: Int?
        let axFrame: String?
    }

    var identifier: String? {
        id
    }

    /// The iOS type such as `TextField`, else the neutral role.
    var type: String {
        native.type ?? role
    }
}

struct DescribeUIEnvelope: Decodable {
    struct Screen: Decodable {
        let width: Double
        let height: Double
        let scale: Double?
        let orientation: String?
    }

    let version: Int
    let platform: String
    let device: String
    let screen: Screen?
    let roots: [UIElement]
}

struct UIStateParser {
    static func parseDescribeUIEnvelope(_ jsonString: String) throws -> DescribeUIEnvelope {
        var jsonContent = jsonString

        if let jsonStart = jsonString.firstIndex(of: "{") {
            jsonContent = String(jsonString[jsonStart...])
        }

        guard let data = jsonContent.data(using: .utf8) else {
            throw TestError.invalidJSON("Could not convert string to data")
        }

        return try JSONDecoder().decode(DescribeUIEnvelope.self, from: data)
    }

    static func parseDescribeUIRoots(_ jsonString: String) throws -> [UIElement] {
        try parseDescribeUIEnvelope(jsonString).roots
    }

    static func parseDescribeUIOutput(_ jsonString: String) throws -> UIElement {
        let elements = try parseDescribeUIRoots(jsonString)
        guard let firstElement = elements.first else {
            throw TestError.invalidJSON("No UI elements found")
        }
        return firstElement
    }

    static func findElement(in root: UIElement, matching predicate: (UIElement) -> Bool) -> UIElement? {
        if predicate(root) {
            return root
        }

        if let children = root.children {
            for child in children {
                if let found = findElement(in: child, matching: predicate) {
                    return found
                }
            }
        }

        return nil
    }

    static func findElement(in root: UIElement, withIdentifier identifier: String) -> UIElement? {
        findElement(in: root) { element in
            element.identifier == identifier
        }
    }

    static func findElementByLabel(in root: UIElement, label: String) -> UIElement? {
        findElement(in: root) { element in
            element.label == label
        }
    }

    static func findElementContainingLabel(in root: UIElement, containing: String) -> UIElement? {
        findElement(in: root) { element in
            element.label?.contains(containing) == true
        }
    }

    static func findElement(in roots: [UIElement], matching predicate: (UIElement) -> Bool) -> UIElement? {
        for root in roots {
            if let element = findElement(in: root, matching: predicate) {
                return element
            }
        }

        return nil
    }

    static func findElement(in roots: [UIElement], withIdentifier identifier: String) -> UIElement? {
        findElement(in: roots) { element in
            element.identifier == identifier
        }
    }
}
