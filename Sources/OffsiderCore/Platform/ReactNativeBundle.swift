import Foundation

/// Spots a React Native iOS app from its `.app` bundle, so simulator typing can wait for its JavaScript between keys.
public enum ReactNativeBundle {
    /// A Release build embeds its JavaScript; any build ships React's resource bundle or a React or Hermes framework.
    static let markers = ["main.jsbundle", "React-Core_privacy.bundle"]
    static let frameworks: Set<String> = ["React.framework", "ReactNativeDependencies.framework", "hermes.framework", "hermesvm.framework"]

    /// True when the bundle at `appPath` holds React Native.
    public static func isReactNative(appPath: String, fileManager: FileManager = .default) -> Bool {
        let app = URL(fileURLWithPath: appPath)
        if markers.contains(where: { fileManager.fileExists(atPath: app.appendingPathComponent($0).path) }) { return true }
        let bundled = (try? fileManager.contentsOfDirectory(atPath: app.appendingPathComponent("Frameworks").path)) ?? []
        return bundled.contains(where: frameworks.contains)
    }

    /// The `.app` folder that holds an executable, or nil when the path is not inside one.
    public static func appPath(ofExecutable path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url.path }
        }
        return nil
    }

    /// The app at the root of an iOS simulator tree is React Native; `processPath` maps a pid to its executable, as simulator apps run on the Mac.
    public static func isFront(in tree: UITree?, processPath: (Int32) -> String? = ProcessPath.of(pid:)) -> Bool {
        guard let tree, tree.platform == .ios,
              let pid = (tree.roots.first { $0.role == .application } ?? tree.roots.first)?.iosPID.flatMap(Int32.init(exactly:)),
              let executable = processPath(pid), let app = appPath(ofExecutable: executable) else { return false }
        return isReactNative(appPath: app)
    }
}
