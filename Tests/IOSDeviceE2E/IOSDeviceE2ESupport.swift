import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

let isIOSDeviceE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_IOS_DEVICE_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()

struct IOSDeviceE2EError: Error, CustomStringConvertible {
    let description: String
}

/// The pure decisions behind the iOS device suites: only the exact OFFSIDER_IOS_DEVICE UDID, listed as a physical iPhone or iPad.
enum IOSDeviceE2EGuard {
    /// What can be decided before any devicectl call: a UDID is named, and it has a physical device's shape.
    static func preflight(requested: String?) -> Result<String, IOSDeviceE2EError> {
        let requested = requested?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !requested.isEmpty else {
            return .failure(IOSDeviceE2EError(description: "OFFSIDER_IOS_DEVICE must name the iPhone or iPad's UDID; the suites never pick a device."))
        }
        guard requested.wholeMatch(of: #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}/#) != nil || requested.wholeMatch(of: #/[0-9a-fA-F]{40}/#) != nil else {
            return .failure(IOSDeviceE2EError(description: "Refusing \(requested): OFFSIDER_IOS_DEVICE must be a physical device's UDID, never a simulator or a name."))
        }
        return .success(requested)
    }

    /// The UDID when `devicectl list devices` lists exactly it as a physical iOS or iPadOS device.
    static func verdict(requested raw: String?, listing: Data) -> Result<String, IOSDeviceE2EError> {
        let requested: String
        switch preflight(requested: raw) {
        case .success(let value): requested = value
        case .failure(let error): return .failure(error)
        }
        guard let root = try? JSONSerialization.jsonObject(with: listing) as? [String: Any],
              let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            return .failure(IOSDeviceE2EError(description: "devicectl list devices printed no device list."))
        }
        guard let row = devices.first(where: { hardware($0)["udid"] as? String == requested }) else {
            return .failure(IOSDeviceE2EError(description: "Refusing \(requested): `devicectl list devices` does not list it. Connect it by cable and trust this Mac."))
        }
        let reality = hardware(row)["reality"] as? String ?? "unknown"
        guard reality == "physical" else {
            return .failure(IOSDeviceE2EError(description: "Refusing \(requested): devicectl lists it as \(reality), and the iOS device suites drive only a physical device."))
        }
        let platform = hardware(row)["platform"] as? String ?? "unknown"
        guard platform == "iOS" || platform == "iPadOS" else {
            return .failure(IOSDeviceE2EError(description: "Refusing \(requested): its platform is \(platform), not iOS or iPadOS."))
        }
        return .success(requested)
    }

    /// Xcode 27's `properties.hardware`, else the older `hardwareProperties` block.
    private static func hardware(_ row: [String: Any]) -> [String: Any] {
        ((row["properties"] as? [String: Any])?["hardware"] as? [String: Any]) ?? (row["hardwareProperties"] as? [String: Any]) ?? [:]
    }

    /// The team the runner and the playground are signed with.
    static func team(_ value: String?) -> Result<String, IOSDeviceE2EError> {
        let value = value?.trimmingCharacters(in: .whitespaces) ?? ""
        guard value.wholeMatch(of: #/[A-Z0-9]{10}/#) != nil else {
            return .failure(IOSDeviceE2EError(description: "OFFSIDER_IOS_TEAM_ID must name the 10-character team that signs the runner and the playground."))
        }
        return .success(value)
    }

    /// Why input and tree suites cannot run, from `info displays`: nil when the screen is on.
    /// `lockState` has no locked-now flag, so a dark screen is the signal; a passcode makes it probably locked too.
    static func asleepReason(displays: Data, lockState: Data, deviceType: String) -> String? {
        let backlight = (result(displays)?["backlightState"] as? String)
        let passcode = result(lockState)?["passcodeRequired"] as? Bool
        switch backlight {
        case nil:
            return "skipped: \(deviceType) asleep or locked (devicectl reported no screen state)"
        case "off"?:
            return "skipped: \(deviceType) asleep or locked (screen off\(passcode == true ? ", passcode set" : ""))"
        default:
            return nil
        }
    }

    /// Whether a playground build or install failed for signing or a locked device, which the suites skip rather than fail.
    static func isSigningOrLock(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return ["provisioning profile", "no accounts", "signing", "integrity could not be verified", "0xe8008012", "locked", "no signing certificate"]
            .contains { lowered.contains($0) }
    }

    static func result(_ data: Data) -> [String: Any]? {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let root = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any] else { return nil }
        return root["result"] as? [String: Any]
    }
}

/// Resolves OFFSIDER_IOS_DEVICE once from `devicectl list devices`; never falls back to another device.
actor GuardedIOSDevice {
    static let shared = GuardedIOSDevice()
    private var resolved: (udid: String, deviceType: String)?
    private var playground: Result<Void, IOSDeviceE2EError>?

    func device() async throws -> (udid: String, deviceType: String) {
        if let resolved { return resolved }
        let requested = ProcessInfo.processInfo.environment["OFFSIDER_IOS_DEVICE"]
        _ = try IOSDeviceE2EGuard.preflight(requested: requested).get()
        let listing = try await CommandRunner.runSeparated("xcrun devicectl list devices --json-output - -q", timeout: 60)
        guard listing.exitCode == 0 else {
            throw IOSDeviceE2EError(description: "devicectl list devices exited \(listing.exitCode): \(listing.stderr)")
        }
        let udid = try IOSDeviceE2EGuard.verdict(requested: requested, listing: Data(listing.stdout.utf8)).get()
        let deviceType = Self.deviceType(udid: udid, listing: Data(listing.stdout.utf8))
        resolved = (udid, deviceType)
        return (udid, deviceType)
    }

    private static func deviceType(udid: String, listing: Data) -> String {
        let devices = IOSDeviceE2EGuard.result(listing)?["devices"] as? [[String: Any]] ?? []
        let row = devices.first { (($0["properties"] as? [String: Any])?["hardware"] as? [String: Any])?["udid"] as? String == udid }
        return ((row?["properties"] as? [String: Any])?["hardware"] as? [String: Any])?["deviceType"] as? String ?? "device"
    }

    /// Runs `body` once per test run; a failure is remembered so later tests skip or fail the same way without retrying.
    func installOnce(_ body: () async throws -> Void) async -> Result<Void, IOSDeviceE2EError> {
        if let playground { return playground }
        do {
            try await body()
            playground = .success(())
        } catch let error as IOSDeviceE2EError {
            playground = .failure(error)
        } catch {
            playground = .failure(IOSDeviceE2EError(description: "\(error)"))
        }
        return playground!
    }
}

/// devicectl, offsider and describe-ui helpers for the iOS device suites, all bound to the guarded UDID.
enum IOSDeviceE2E {
    static let playgroundBundleID = "com.mpalmes.offsider.playground"
    static let playgroundProject = "OffsiderPlaygroundApp/OffsiderPlayground.xcodeproj"
    static let playgroundScheme = "OffsiderPlayground"

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func udid() async throws -> String {
        try await GuardedIOSDevice.shared.device().udid
    }

    static func team() throws -> String {
        try IOSDeviceE2EGuard.team(ProcessInfo.processInfo.environment["OFFSIDER_IOS_TEAM_ID"]).get()
    }

    /// Runs offsider with `--device` set to the guarded UDID.
    static func offsider(_ arguments: String, environment: [String: String]? = nil, timeout: TimeInterval = 300) async throws -> SeparatedCommandOutput {
        let udid = try await udid()
        return try await TestHelpers.runOffsiderCommandSeparated("\(arguments) --device \(udid)", environment: environment, timeout: timeout)
    }

    /// Like `offsider`, but a non-zero exit is an error carrying stderr.
    @discardableResult
    static func run(_ arguments: String, environment: [String: String]? = nil, timeout: TimeInterval = 300) async throws -> SeparatedCommandOutput {
        let result = try await offsider(arguments, environment: environment, timeout: timeout)
        guard result.exitCode == 0 else {
            throw IOSDeviceE2EError(description: "offsider \(arguments) exited \(result.exitCode): \(result.stderr)")
        }
        return result
    }

    /// `xcrun devicectl <arguments> --device <udid>`, its stdout on success.
    @discardableResult
    static func devicectl(_ arguments: String, timeout: TimeInterval = 120) async throws -> String {
        let udid = try await udid()
        // `--device` goes straight after the subcommand words: after `launch`'s bundle ID everything belongs to the app.
        let words = arguments.split(separator: " ", omittingEmptySubsequences: false)
        let subcommand = words.prefix { !$0.hasPrefix("-") }
        let placed = (subcommand + ["--device", Substring(udid)] + words.dropFirst(subcommand.count)).joined(separator: " ")
        let result = try await CommandRunner.runSeparated("xcrun devicectl \(placed)", timeout: timeout)
        guard result.exitCode == 0 else {
            throw IOSDeviceE2EError(description: "devicectl \(arguments) exited \(result.exitCode): \(result.stderr)\(result.stdout)")
        }
        return result.stdout
    }

    /// One `devicectl device info <what>` reply.
    static func info(_ what: String) async throws -> Data {
        Data(try await devicectl("device info \(what) --timeout 20 --json-output - -q").utf8)
    }

    /// Ends the test as skipped, with a note on stderr, when the device's screen is off: input and the runner need it awake and unlocked.
    static func requireAwake() async throws {
        let deviceType = try await GuardedIOSDevice.shared.device().deviceType
        let reason = IOSDeviceE2EGuard.asleepReason(displays: try await info("displays"), lockState: try await info("lockState"), deviceType: deviceType)
        if let reason {
            FileHandle.standardError.write(Data((reason + "\n").utf8))
            try Test.cancel(Comment(rawValue: reason))
        }
    }

    /// The tree of the playground through the runner.
    static let describeUI = DescribeUITree(
        read: { try DescribeUITree.parse(try await run("describe-ui --app \(playgroundBundleID)").stdout) }
    )

    static func waitForNode(timeout: TimeInterval = 30, where predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        try await describeUI.waitForNode(timeout: timeout, where: predicate)
    }

    /// The guarded device's row in `session status --json`: its runner and broker, each nil when not running.
    static func sessions() async throws -> (runner: [String: Any]?, broker: [String: Any]?) {
        let udid = try await udid()
        let result = try await run("session status --json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], "session status printed no JSON")
        let rows = try #require(object["sessions"] as? [[String: Any]])
        let row = rows.first { $0["device"] as? String == udid }
        return (row?["runner"] as? [String: Any], row?["broker"] as? [String: Any])
    }

    /// Fails unless the broker is running, answering and sending touches and keys itself, so input did not fall back to the runner.
    static func requireBrokerInput() async throws {
        let broker = try #require(try await sessions().broker, "no session broker is running after input")
        #expect(broker["running"] as? Bool == true)
        #expect(broker["answering"] as? Bool == true)
        #expect(broker["touch"] as? Bool == true, "the broker does not send touches: \(broker)")
    }

    /// A node's frame in the points describe-ui prints.
    static func frame(of node: [String: Any]) throws -> (x: Double, y: Double, width: Double, height: Double) {
        let frame = try #require(node["frame"] as? [String: Any], "\(node["label"] ?? node["role"] ?? "a node") has no frame")
        func number(_ key: String) throws -> Double { try #require((frame[key] as? NSNumber)?.doubleValue, "a frame has no \(key)") }
        return (try number("x"), try number("y"), try number("width"), try number("height"))
    }

    /// The first node labelled `label`, waiting for it.
    static func node(labelled label: String, timeout: TimeInterval = 30) async throws -> [String: Any] {
        try await waitForNode(timeout: timeout) { $0["label"] as? String == label }
    }

    /// The point inside `node`'s frame at fractions of its width and height, rounded to whole points.
    static func point(in node: [String: Any], x: Double = 0.5, y: Double = 0.5) throws -> (x: Int, y: Int) {
        let frame = try frame(of: node)
        return (Int((frame.x + frame.width * x).rounded()), Int((frame.y + frame.height * y).rounded()))
    }

    /// The pair in a playground label such as `End: (1,120, 600)`, whose numbers may carry grouping commas.
    static func coordinates(in label: String) -> (x: Int, y: Int)? {
        guard let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"), open < close else { return nil }
        let numbers = label[label.index(after: open)..<close].components(separatedBy: ", ").compactMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }

    /// The screen describe-ui reports for the playground, in points.
    static func screen() async throws -> (width: Double, height: Double) {
        let tree = try DescribeUITree.parse(try await run("describe-ui --app \(playgroundBundleID)").stdout)
        let screen = try #require(tree["screen"] as? [String: Any], "describe-ui reported no screen")
        return (try #require((screen["width"] as? NSNumber)?.doubleValue), try #require((screen["height"] as? NSNumber)?.doubleValue))
    }

    static func screenshot(_ name: String, flags: String = "") async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-ios-device-e2e-\(UUID().uuidString)-\(name)")
        try await run("screenshot \(flags) --output \(quote(output.path))")
        return output
    }

    static func pngSize(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw IOSDeviceE2EError(description: "\(url.lastPathComponent) is not a PNG ImageIO can read")
        }
        return (width, height)
    }
}

extension IOSDeviceE2E {
    /// Builds, signs and installs the playground unless this device already has this exact build (a source digest in a marker);
    /// a signing or lock failure ends the test as skipped with the exact error on stderr.
    static func ensurePlaygroundInstalled() async throws {
        let result = await GuardedIOSDevice.shared.installOnce {
            let udid = try await udid()
            let team = try team()
            let digest = try playgroundDigest(team: team)
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-ios-device-e2e")
            let marker = workspace.appendingPathComponent("\(udid)-playground.sha256")
            if (try? String(contentsOf: marker, encoding: .utf8)) == digest { return }
            let app = try await buildPlayground(team: team, derivedData: workspace.appendingPathComponent("DerivedData"))
            let install = try await CommandRunner.runSeparated("xcrun devicectl device install app --device \(udid) \(quote(app))", timeout: 300)
            guard install.exitCode == 0 else {
                throw IOSDeviceE2EError(description: "devicectl device install app exited \(install.exitCode): \(install.stderr)\(install.stdout)")
            }
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try digest.write(to: marker, atomically: true, encoding: .utf8)
        }
        if case .failure(let error) = result {
            guard IOSDeviceE2EGuard.isSigningOrLock(error.description) else { throw error }
            let note = "skipped: the playground could not be installed for a signing or lock reason: \(error.description)"
            FileHandle.standardError.write(Data((note + "\n").utf8))
            try Test.cancel(Comment(rawValue: note))
        }
    }

    /// Restarts the playground on one screen and waits until describe-ui shows a node labelled `label`.
    /// The runner's snapshot gives every element on a screen the screen's identifier, so the suites find nodes by label and role.
    static func open(_ screen: String, waitingForLabel label: String) async throws {
        try await ensurePlaygroundInstalled()
        let launch = "device process launch --terminate-existing --timeout 60 \(playgroundBundleID) -- --launch-arg screen=\(screen)"
        do {
            try await devicectl(launch)
        } catch {
            // devicectl sometimes loses the new process's identifier as the old one is terminated; a second launch settles it.
            try await Task.sleep(for: .seconds(1))
            try await devicectl(launch)
        }
        _ = try await node(labelled: label, timeout: 60)
        // The tree is ready before the launch animation ends, and a swipe sent during it never reaches the app.
        try await Task.sleep(for: .seconds(2))
    }

    private static func playgroundDigest(team: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("OffsiderPlaygroundApp")
        var hasher = SHA256()
        hasher.update(data: Data(team.utf8))
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" || $0.pathExtension == "json" || $0.lastPathComponent == "project.yml" }
            .filter { !$0.path.contains(".xcodeproj/") }
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw IOSDeviceE2EError(description: "No playground sources under \(root.path); run the suites from the repository root.") }
        for file in files {
            hasher.update(data: Data(file.path.dropFirst(root.path.count).utf8))
            hasher.update(data: try Data(contentsOf: file))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The playground's project is generated and git-ignored, so XcodeGen makes it first when it is missing.
    /// The project signs ad hoc for simulators; a device build overrides that with automatic signing for the team.
    private static func buildPlayground(team: String, derivedData: URL) async throws -> String {
        if !FileManager.default.fileExists(atPath: playgroundProject) {
            let generate = try await CommandRunner.runSeparated("xcodegen generate --spec OffsiderPlaygroundApp/project.yml --quiet", timeout: 120)
            guard generate.exitCode == 0 else {
                throw IOSDeviceE2EError(description: "xcodegen generate exited \(generate.exitCode): \(generate.stderr)")
            }
        }
        let build = try await CommandRunner.runSeparated(
            "xcodebuild -project \(playgroundProject) -scheme \(playgroundScheme) -destination 'generic/platform=iOS' "
                + "-derivedDataPath \(quote(derivedData.path)) DEVELOPMENT_TEAM=\(team) CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' "
                + "-allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build",
            timeout: 600
        )
        guard build.exitCode == 0 else {
            let errors = (build.stdout + build.stderr).split(whereSeparator: \.isNewline).filter { $0.contains("error:") }.prefix(5).joined(separator: "\n")
            throw IOSDeviceE2EError(description: "xcodebuild for the playground exited \(build.exitCode): \(errors)")
        }
        let app = derivedData.appendingPathComponent("Build/Products/Debug-iphoneos/\(playgroundScheme).app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw IOSDeviceE2EError(description: "xcodebuild left no app at \(app.path)")
        }
        return app.path
    }
}
