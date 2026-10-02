import Foundation
import OffsiderCore
import Testing

@Suite("Expo dev client preparing")
struct ExpoDevClientTests {
    @Test("bundle IDs and packages pass, shell metacharacters and bare names do not", arguments: [
        ("com.example.app", true),
        ("com.mpalmes.offsider.playground.rn", true),
        ("com.example.my-app", true),
        ("com.example.my_app", true),
        ("app", false),
        ("com.example;reboot", false),
        ("com.example app", false),
        ("com.example.$(id)", false),
    ])
    func validation(appID: String, valid: Bool) {
        let accepted = (try? ExpoDevClient.validate(appID: appID)) != nil
        #expect(accepted == valid)
    }

    @Test("iOS writes both keys to the app's own plist by path, not the device-wide domain")
    func iosWritesTheContainerPlist() {
        let writes = ExpoDevClient.iosDefaultsWriteArguments(udid: "UDID", dataContainer: "/data/Containers/X", bundleID: "com.example.app")
        let domain = "/data/Containers/X/Library/Preferences/com.example.app"
        #expect(writes == [
            ["simctl", "spawn", "UDID", "defaults", "write", domain, "EXDevMenuIsOnboardingFinished", "-bool", "YES"],
            ["simctl", "spawn", "UDID", "defaults", "write", domain, "EXDevMenuShowsAtLaunch", "-bool", "NO"],
        ])
    }

    @Test("iOS read-back needs the intro finished and the launch menu off")
    func iosConfirmation() {
        #expect(ExpoDevClient.iosDefaultsConfirmed("{\n    EXDevMenuIsOnboardingFinished = 1;\n    EXDevMenuShowsAtLaunch = 0;\n}\n"))
        #expect(!ExpoDevClient.iosDefaultsConfirmed("{\n    EXDevMenuIsOnboardingFinished = 1;\n    EXDevMenuShowsAtLaunch = 1;\n}\n"))
        #expect(!ExpoDevClient.iosDefaultsConfirmed("{\n    EXDevMenuShowsAtLaunch = 0;\n}\n"))
    }

    @Test("an iOS Release build and a plain React Native app are refused with what to install")
    func iosBundleClassification() {
        #expect(ExpoDevClient.iosBundleError(bundleID: "a.b", hasDevMenu: true, hasEmbeddedBundle: false) == nil)
        let release = ExpoDevClient.iosBundleError(bundleID: "a.b", hasDevMenu: false, hasEmbeddedBundle: true)
        #expect(release?.kind == .releaseBuild)
        #expect(release?.message.contains("Debug build") == true)
        #expect(ExpoDevClient.iosBundleError(bundleID: "a.b", hasDevMenu: false, hasEmbeddedBundle: false)?.kind == .notDevClient)
    }

    @Test("Android run-as refusals map to the build the user must install")
    func androidRunAsErrors() {
        #expect(ExpoDevClient.androidRunAsError(package: "a.b", output: "run-as: package not debuggable: a.b")?.kind == .notDebuggable)
        #expect(ExpoDevClient.androidRunAsError(package: "a.b", output: "run-as: unknown package: a.b")?.kind == .notInstalled)
        #expect(ExpoDevClient.androidRunAsError(package: "a.b", output: "sed: bad option") == nil)
    }

    @Test("Android install and dev client checks read pm path and dumpsys")
    func androidChecks() {
        #expect(ExpoDevClient.androidIsInstalled(pmPathOutput: "package:/data/app/~~x/a.b-1/base.apk\n"))
        #expect(!ExpoDevClient.androidIsInstalled(pmPathOutput: ""))
        #expect(ExpoDevClient.androidIsDevClient(packageDump: "  1a2b3c a.b/expo.modules.devlauncher.compose.AuthActivity filter"))
        #expect(!ExpoDevClient.androidIsDevClient(packageDump: "  1a2b3c a.b/.MainActivity filter"))
    }

    @Test("the Android script creates the preferences file when the app has none")
    func androidScriptCreates() throws {
        let sandbox = try ScriptSandbox()
        let output = try sandbox.run(ExpoDevClient.androidWriteCommand(package: "com.example.app"))
        #expect(ExpoDevClient.androidPrefsConfirmed(output))
        #expect(try sandbox.preferences() == ["isOnboardingFinished": "true", "showsAtLaunch": "false"])
    }

    @Test("the Android script replaces stale values and keeps the app's other preferences")
    func androidScriptMerges() throws {
        let sandbox = try ScriptSandbox()
        try sandbox.writePreferences("""
        <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
        <map>
            <boolean name="motionGestureEnabled" value="true" />
            <boolean name="isOnboardingFinished" value="false" />
            <boolean name="showsAtLaunch" value="true" />
        </map>
        """)
        _ = try sandbox.run(ExpoDevClient.androidWriteCommand(package: "com.example.app"))
        _ = try sandbox.run(ExpoDevClient.androidWriteCommand(package: "com.example.app"))
        #expect(try sandbox.preferences() == ["motionGestureEnabled": "true", "isOnboardingFinished": "true", "showsAtLaunch": "false"])
        let xml = try String(contentsOf: sandbox.preferencesURL, encoding: .utf8)
        #expect(xml.components(separatedBy: #"name="isOnboardingFinished""#).count == 2, "the key is written once")
    }

    @Test("the Android script fills an empty preferences map")
    func androidScriptFillsEmptyMap() throws {
        let sandbox = try ScriptSandbox()
        try sandbox.writePreferences("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map />\n")
        _ = try sandbox.run(ExpoDevClient.androidWriteCommand(package: "com.example.app"))
        #expect(try sandbox.preferences() == ["isOnboardingFinished": "true", "showsAtLaunch": "false"])
    }
}

/// Runs the device command with /bin/sh in a temporary app data directory, with `run-as` and toybox-style `sed -i` stand-ins.
private struct ScriptSandbox {
    let root: URL
    let bin: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("expo-dev-client-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Self.tool(at: bin.appendingPathComponent("run-as"), "#!/bin/sh\nshift\nexec \"$@\"\n")
        try Self.tool(at: bin.appendingPathComponent("sed"), "#!/bin/sh\nif [ \"$1\" = \"-i\" ]; then shift; exec /usr/bin/sed -i '' \"$@\"; fi\nexec /usr/bin/sed \"$@\"\n")
    }

    private static func tool(at url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var preferencesURL: URL { root.appendingPathComponent(ExpoDevClient.androidPreferencesFile) }

    func writePreferences(_ xml: String) throws {
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try xml.write(to: preferencesURL, atomically: true, encoding: .utf8)
    }

    func run(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = root
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ScriptFailure(output: output)
        }
        return output
    }

    /// Parses the file as Android's XmlUtils would see it: every `<boolean>` by name.
    func preferences() throws -> [String: String] {
        let collector = BooleanCollector()
        let parser = XMLParser(data: try Data(contentsOf: preferencesURL))
        parser.delegate = collector
        guard parser.parse() else {
            throw ScriptFailure(output: "invalid XML: \(String(describing: parser.parserError))")
        }
        return collector.values
    }
}

private struct ScriptFailure: Error, CustomStringConvertible {
    let output: String
    var description: String { output }
}

private final class BooleanCollector: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "boolean", let key = attributes["name"] {
            values[key] = attributes["value"]
        }
    }
}
