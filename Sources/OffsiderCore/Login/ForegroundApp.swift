import Foundation

/// The app in front: an iOS bundle id read from the simulator process, or the Android package on the tree.
public enum ForegroundApp {
    public enum Failure: Equatable, Error, Sendable {
        case notInFront
        case unreadableExecutable(Int)
        case missingBundleIdentifier
        case severalPackages([String])
    }

    /// `pathForPID` maps an iOS accessibility pid to the host executable path. Android ignores it.
    public static func identifier(in tree: UITree, pathForPID: (Int) -> String?) throws -> String {
        switch tree.platform {
        case .android:
            return try package(in: tree)
        case .ios:
            return try bundleIdentifier(in: tree, pathForPID: pathForPID)
        }
    }

    /// `CFBundleIdentifier` from the `.app` that contains `path`.
    public static func bundleIdentifier(atExecutable path: String, fileManager: FileManager = .default) -> String? {
        var directory = (path as NSString).deletingLastPathComponent
        for _ in 0..<4 {
            if directory.hasSuffix(".app") {
                let plist = (directory as NSString).appendingPathComponent("Info.plist")
                guard let data = fileManager.contents(atPath: plist),
                      let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = object["CFBundleIdentifier"] as? String,
                      !identifier.isEmpty
                else { return nil }
                return identifier
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    private static func bundleIdentifier(in tree: UITree, pathForPID: (Int) -> String?) throws -> String {
        let nodes = tree.roots.flatMap { $0.flattened() }
        let app = nodes.first { $0.role == .application } ?? tree.roots.first
        guard let app, case .ios(let native) = app.native, let pid = native.pid else { throw Failure.notInFront }
        guard let path = pathForPID(pid) else { throw Failure.unreadableExecutable(pid) }
        guard let identifier = bundleIdentifier(atExecutable: path) else { throw Failure.missingBundleIdentifier }
        return identifier
    }

    private static func package(in tree: UITree) throws -> String {
        let keyboardPackages = keyboardPackages(in: tree)
        let point = tree.viewport?.center ?? UIPoint(x: 1, y: 1)
        if let package = tree.hitChain(at: point).reversed().compactMap(package(of:)).first(where: { !keyboardPackages.contains($0) }) {
            return package
        }
        let packages = Set(tree.roots.flatMap { $0.flattened() }.compactMap(package(of:))).subtracting(keyboardPackages)
        if packages.count == 1, let only = packages.first { return only }
        if packages.isEmpty { throw Failure.notInFront }
        throw Failure.severalPackages(packages.sorted())
    }

    /// Packages of the software keyboard. Its window can cover the screen without being the app in front.
    private static func keyboardPackages(in tree: UITree) -> Set<String> {
        Set(tree.roots.flatMap { $0.flattened() }.filter { $0.role == .keyboard }.flatMap { $0.flattened().compactMap(package(of:)) })
    }

    private static func package(of node: UINode) -> String? {
        guard case .android(let attributes) = node.native else { return nil }
        let package = attributes.package?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let package, !package.isEmpty else { return nil }
        return package
    }
}
