import Foundation

/// Whether a folder sits in a git work tree, read from the `.git` entry a checkout or linked work tree has; no git process runs.
public enum GitWorkTree {
    /// The work tree's top folder, or nil when `path` and its parents hold no `.git`.
    public static func root(containing path: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        var folder = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if exists(folder.appendingPathComponent(".git").path) { return folder.path }
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { return nil }
            folder = parent
        }
    }
}
