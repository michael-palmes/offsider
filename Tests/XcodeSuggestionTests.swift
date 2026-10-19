import Foundation
import OffsiderCore
import Testing

@Suite("Xcode suggestion")
struct XcodeSuggestionTests {
    @Test("the newest Apple-signed Xcode is suggested with sudo, and DEVELOPER_DIR is the no-sudo choice")
    func newestSigned() {
        let suggestion = XcodeSuggestion(bundles: [
            XcodeBundle(path: "/Applications/Xcode.app", version: "26.4", appleSigned: true),
            XcodeBundle(path: "/Applications/Xcode-beta.app", version: "27.0", appleSigned: true),
            XcodeBundle(path: "/Applications/Xcode-patched.app", version: "28.0", appleSigned: false),
        ])
        #expect(suggestion.select == "sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer")
        #expect(suggestion.environment == "export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer")
        #expect(suggestion.advice.contains("`sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer`"))
    }

    @Test("versions compare by number, Xcode.app wins a tie, and an unsigned bundle is never named")
    func ordering() {
        let ordered = XcodeSuggestion.ordered([
            XcodeBundle(path: "/Applications/Xcode-9.app", version: "9.4", appleSigned: true),
            XcodeBundle(path: "/Applications/Xcode-26.app", version: "26.10", appleSigned: true),
            XcodeBundle(path: "/Applications/Xcode.app", version: "26.10", appleSigned: true),
            XcodeBundle(path: "/Applications/Xcode-26.2.app", version: "26.2", appleSigned: true),
            XcodeBundle(path: "/Applications/Xcode-fake.app", version: "99.0", appleSigned: false),
        ])
        #expect(ordered.map(\.path) == ["/Applications/Xcode.app", "/Applications/Xcode-26.app", "/Applications/Xcode-26.2.app", "/Applications/Xcode-9.app"])
    }

    @Test("with no signed Xcode the fix is to install one, and the message offers no DEVELOPER_DIR")
    func nothingToSelect() {
        let suggestion = XcodeSuggestion(bundles: [XcodeBundle(path: "/Applications/Xcode-fake.app", version: "27.0", appleSigned: false)])
        #expect(suggestion.select == "Install Xcode 26 or later from the Mac App Store or developer.apple.com.")
        #expect(suggestion.advice == suggestion.select)
        #expect(suggestion.adding(to: "No Xcode.") == "No Xcode.")
        #expect(XcodeSuggestion(developerDirectory: "/Applications/Xcode.app/Contents/Developer").adding(to: "No Xcode.")
            == "No Xcode. Without sudo, run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead.")
    }

    @Test("a version floor skips older Xcodes, and a too-old CoreDevice gets the first launch or the install at that floor")
    func versionFloor() {
        let bundles = [
            XcodeBundle(path: "/Applications/Xcode.app", version: "26.4", appleSigned: true),
            XcodeBundle(path: "/Applications/Xcode-27.1.app", version: "27.1", appleSigned: true),
        ]
        #expect(XcodeSuggestion(bundles: bundles, minimumMajor: 27).firstLaunch
            == "sudo xcode-select -s /Applications/Xcode-27.1.app/Contents/Developer && sudo xcodebuild -runFirstLaunch")
        let older = XcodeSuggestion(bundles: Array(bundles.prefix(1)), minimumMajor: 27)
        #expect(older.firstLaunch == "Install Xcode 27 or later from the Mac App Store or developer.apple.com.")
        #expect(older.select == older.firstLaunch)
    }

    @Test("the refused Xcode is skipped, also when a symlink names it, and the next newest is named")
    func skipsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("Xcode-27.1.app/Contents/Developer", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Xcode.app"), withDestinationURL: root.appendingPathComponent("Xcode-27.1.app"))
        let bundles = [
            XcodeBundle(path: root.path + "/Xcode.app", version: "27.1", appleSigned: true),
            XcodeBundle(path: root.path + "/Xcode-27.1.app", version: "27.1", appleSigned: true),
            XcodeBundle(path: "/Applications/Xcode-26.4.app", version: "26.4", appleSigned: true),
        ]
        let suggestion = XcodeSuggestion(bundles: bundles, rejecting: real.path)
        #expect(suggestion.developerDirectory == "/Applications/Xcode-26.4.app/Contents/Developer")
        #expect(XcodeSuggestion(bundles: Array(bundles.prefix(2)), rejecting: root.path + "/Xcode.app/Contents/Developer").select == XcodeSuggestion.install)
    }

    @Test("a scan finds Xcode bundles with a developer folder and asks the validator about each")
    func scan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Xcode.app", "Xcode-beta.app", "Xcode-empty.app", "Other.app"] {
            let contents = root.appendingPathComponent("\(name)/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            if name != "Xcode-empty.app" {
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("Developer"), withIntermediateDirectories: true)
            }
            let version = name == "Xcode-beta.app" ? "27.0" : "26.4"
            try (["CFBundleShortVersionString": version] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        }
        let bundles = XcodeSuggestion.scan(root.path) { $0.hasSuffix("/Xcode.app") ? nil : .notAppleSigned }
        #expect(Set(bundles.map { ($0.path as NSString).lastPathComponent }) == ["Xcode.app", "Xcode-beta.app"])
        #expect(XcodeSuggestion(bundles: bundles).developerDirectory == root.path + "/Xcode.app/Contents/Developer")
    }
}
