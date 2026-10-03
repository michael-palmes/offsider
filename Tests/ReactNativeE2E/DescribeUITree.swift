import Foundation

struct DescribeUIError: Error, CustomStringConvertible {
    let description: String
}

/// Walks `describe-ui` JSON on any platform; `read` runs describe-ui on the device and returns the parsed object.
struct DescribeUITree {
    let read: () async throws -> [String: Any]
    /// Called with the nodes of each read that has no match, before the next poll.
    var onMiss: (([[String: Any]]) async throws -> Void)?

    init(read: @escaping () async throws -> [String: Any], onMiss: (([[String: Any]]) async throws -> Void)? = nil) {
        self.read = read
        self.onMiss = onMiss
    }

    static func parse(_ stdout: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else {
            throw DescribeUIError(description: "describe-ui printed no JSON object")
        }
        return object
    }

    static func nodes(in tree: [String: Any]) -> [[String: Any]] {
        func walk(_ node: [String: Any]) -> [[String: Any]] {
            [node] + ((node["children"] as? [[String: Any]]) ?? []).flatMap(walk)
        }
        return ((tree["roots"] as? [[String: Any]]) ?? []).flatMap(walk)
    }

    static func node(id: String, in tree: [String: Any]) -> [String: Any]? {
        nodes(in: tree).first { $0["id"] as? String == id }
    }

    /// The centre of a node's frame, rounded, in points or dp.
    static func centre(of node: [String: Any]) -> (x: Int, y: Int)? {
        guard let frame = node["frame"] as? [String: Double],
              let x = frame["x"], let y = frame["y"], let width = frame["width"], let height = frame["height"] else {
            return nil
        }
        return (Int((x + width / 2).rounded()), Int((y + height / 2).rounded()))
    }

    /// The `screen` size when reported, else the application root's frame.
    static func screenSize(in tree: [String: Any]) -> (width: Double, height: Double)? {
        if let screen = tree["screen"] as? [String: Any], let width = screen["width"] as? Double, let height = screen["height"] as? Double {
            return (width, height)
        }
        let roots = (tree["roots"] as? [[String: Any]]) ?? []
        let root = roots.first { $0["role"] as? String == "application" } ?? roots.first
        guard let frame = root?["frame"] as? [String: Double], let width = frame["width"], let height = frame["height"] else {
            return nil
        }
        return (width, height)
    }

    func tree() async throws -> [String: Any] {
        try await read()
    }

    func label(of id: String) async throws -> String? {
        Self.node(id: id, in: try await read())?["label"] as? String
    }

    /// Polls describe-ui until a node matches, retrying failed reads.
    func waitForNode(timeout: TimeInterval = 20, where predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: (any Error)?
        repeat {
            do {
                let found = Self.nodes(in: try await read())
                if let node = found.first(where: predicate) {
                    return node
                }
                try await onMiss?(found)
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        throw DescribeUIError(description: "no matching node within \(Int(timeout)) s" + (lastError.map { " (last error: \($0))" } ?? ""))
    }

    func waitForLabel(of id: String, timeout: TimeInterval = 20, _ predicate: (String) -> Bool) async throws -> String {
        let node = try await waitForNode(timeout: timeout) { node in
            node["id"] as? String == id && (node["label"] as? String).map(predicate) == true
        }
        return node["label"] as? String ?? ""
    }

    func centre(of id: String) async throws -> (x: Int, y: Int) {
        let node = try await waitForNode { $0["id"] as? String == id }
        guard let centre = Self.centre(of: node) else {
            throw DescribeUIError(description: "\(id) has no frame")
        }
        return centre
    }

    func screenSize() async throws -> (width: Double, height: Double) {
        let tree = try await read()
        guard let size = Self.screenSize(in: tree) else {
            throw DescribeUIError(description: "describe-ui reported no screen size and no application frame")
        }
        return size
    }
}
