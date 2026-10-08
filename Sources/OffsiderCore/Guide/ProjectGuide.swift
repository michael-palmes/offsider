import Foundation

/// A repository's `OFFSIDER.md`: the project's own recipes for agents, found from a path upwards.
public enum ProjectGuide {
    public static let fileName = "OFFSIDER.md"
    public static let maximumBytes = 256 * 1024
    public static let maximumLevels = 32

    public struct Found: Equatable, Sendable {
        public let path: String
        public let text: String
    }

    public enum Failure: Error, Equatable, Sendable {
        case missingPath(String)
        /// None found; `stop` is the last directory searched.
        case notFound(start: String, stop: String)
        case unreadable(path: String, detail: String)
    }

    /// Searches `path` (a file's directory) and each parent, stopping after the first directory holding `.git`, at `home`, at `/` or after 32 levels.
    public static func locate(fileName: String = ProjectGuide.fileName, from path: String, home: String = NSHomeDirectory(), fileManager: FileManager = .default) throws -> Found {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (fileManager.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        var start = URL(fileURLWithPath: absolute).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: start, isDirectory: &isDirectory) else { throw Failure.missingPath(start) }
        if !isDirectory.boolValue { start = (start as NSString).deletingLastPathComponent }
        let home = URL(fileURLWithPath: home).standardizedFileURL.path

        var directory = start
        for _ in 0..<maximumLevels {
            let candidate = (directory as NSString).appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate) {
                return try read(candidate, within: directory, fileManager: fileManager)
            }
            let isRepositoryRoot = fileManager.fileExists(atPath: (directory as NSString).appendingPathComponent(".git"))
            if isRepositoryRoot || directory == home || directory == "/" { break }
            directory = (directory as NSString).deletingLastPathComponent
        }
        throw Failure.notFound(start: start, stop: directory)
    }

    /// A regular file of at most 256 KiB of UTF-8; a symlink is followed only when it stays under `root`.
    static func read(_ path: String, within root: String, fileManager: FileManager) throws -> Found {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(resolvedRoot + "/") else {
            throw Failure.unreadable(path: path, detail: "it links outside \(root)")
        }
        let attributes = try? fileManager.attributesOfItem(atPath: resolved)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.unreadable(path: path, detail: "it is not a regular file")
        }
        guard let size = attributes?[.size] as? Int, size <= maximumBytes else {
            throw Failure.unreadable(path: path, detail: "it is larger than 256 KiB")
        }
        guard let data = fileManager.contents(atPath: resolved), let text = String(data: data, encoding: .utf8) else {
            throw Failure.unreadable(path: path, detail: "it is not UTF-8 text")
        }
        return Found(path: path, text: text)
    }
}
