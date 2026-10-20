import Foundation
import FBControlCore
import FBSimulatorControl
import OffsiderCore

struct AccessibilityRecoveryDependencies {
    typealias ProcessRunner = @MainActor (
        _ executableURL: URL,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) async throws -> Int32
    typealias Waiter = @MainActor (_ duration: Duration) async throws -> Void

    let runProcess: ProcessRunner
    let wait: Waiter

    static let live = AccessibilityRecoveryDependencies(
        runProcess: AccessibilityFetcher.runProcess,
        wait: { duration in try await Task.sleep(for: duration) }
    )
}

struct AccessibilityPoint: Equatable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

// MARK: - Accessibility Fetcher
@MainActor
struct AccessibilityFetcher {
    /// Set by `describe-ui`: an empty tree after the retries checks `launchctl` and warns when an app is running.
    @TaskLocal static var warnsWhenEmpty = false

    static func fetchAccessibilityInfoJSONData(
        for simulatorUDID: String,
        point: AccessibilityPoint? = nil,
        logger: OffsiderLogger,
        recoveryDependencies: AccessibilityRecoveryDependencies = .live
    ) async throws -> Data {
        guard let target = try await cachedSimulator(udid: simulatorUDID, logger: logger) else {
            throw CLIError.deviceNotFound(id: simulatorUDID)
        }
        guard target.state == .booted else {
            throw CLIError.deviceNotBooted(id: simulatorUDID, state: FBiOSTargetStateStringFromState(target.state).rawValue)
        }
        return try await fetchAccessibilityInfoJSONData(
            from: target,
            point: point,
            logger: logger,
            recoveryDependencies: recoveryDependencies
        )
    }

    static func fetchAccessibilityInfoJSONData(
        from target: FBSimulator,
        point: AccessibilityPoint? = nil,
        appPIDs: Set<Int> = [],
        logger: OffsiderLogger,
        recoveryDependencies: AccessibilityRecoveryDependencies = .live
    ) async throws -> Data {
        try await Timings.measure("accessibility") {
            try await retryingAfterTestManagerRecovery(
                simulatorUDID: target.udid,
                logger: logger,
                dependencies: recoveryDependencies
            ) {
                if let point {
                    return try await fetchAccessibilityInfoJSONData(from: target, at: point, appPIDs: appPIDs)
                }
                return try await fetchFrontmostAccessibilityInfoJSONData(from: target)
            }
        }
    }

    private static func fetchAccessibilityInfoJSONData(
        from target: FBSimulator,
        at point: AccessibilityPoint,
        appPIDs: Set<Int>
    ) async throws -> Data {
        try await retryingTransientPointFallback(at: point, appPIDs: appPIDs) {
            let accessibilityElement = try await target.accessibilityElement(at: point.cgPoint)
            defer { accessibilityElement.close() }
            return try serializedAccessibilityData(from: accessibilityElement, keys: TraitsRequest.process.keys)
        }
    }

    /// One point read with no retry and no recovery, for describe-ui's probe, which must stay quick.
    static func probeAccessibilityJSONData(from target: FBSimulator, at point: AccessibilityPoint) async throws -> Data {
        let accessibilityElement = try await target.accessibilityElement(at: point.cgPoint)
        defer { accessibilityElement.close() }
        return try serializedAccessibilityData(from: accessibilityElement, keys: TraitsRequest.process.keys)
    }

    /// Reads `point` again while it answers with an empty screen-sized group; one from a process outside `appPIDs` is that process's view, so it is the answer.
    static func retryingTransientPointFallback(
        at point: AccessibilityPoint,
        appPIDs: Set<Int> = [],
        maximumAttempts: Int = 5,
        fetch: @MainActor () async throws -> Data,
        wait: @MainActor (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) async throws -> Data {
        precondition(maximumAttempts > 0)
        var latestData: Data?
        for attempt in 0..<maximumAttempts {
            let data = try await fetch()
            latestData = data
            if try !isTransientPointFallback(in: data, at: point, appPIDs: appPIDs) {
                return data
            }
            if attempt < maximumAttempts - 1 {
                try await wait(.milliseconds(50 * (1 << attempt)))
            }
        }
        guard let latestData else {
            throw CLIError(errorDescription: "Accessibility element at the requested point could not be serialized.", reason: .treeReadFailed)
        }
        return latestData
    }

    private static func fetchFrontmostAccessibilityInfoJSONData(from target: FBSimulator) async throws -> Data {
        let data = try await readingFrontmostTree { keys in
            // IDB's former `accessibilityElements(withNestedFormat:)` API also serialized the
            // frontmost application internally. This explicit handle API preserves that scope.
            let accessibilityElement = try await target.accessibilityElementForFrontmostApplication()
            defer { accessibilityElement.close() }
            return try serializedAccessibilityData(from: accessibilityElement, keys: keys)
        }
        if warnsWhenEmpty, try !containsAccessibilityDescendant(in: data),
           let listing = await DoctorProbes.runningAppListing(udid: target.udid), let app = SimLaunchctl.likelyForeground(listing) {
            Console.current.notice(emptyTreeNotice(app, udid: target.udid))
        }
        return data
    }

    /// An agent reads the doctor's detail and hint as one `Warning:` line; a person the cause in a few words and the relaunch to try.
    nonisolated static func emptyTreeNotice(_ app: SimLaunchctl.App, udid: String) -> Notice {
        let hint = DoctorRules.emptyTreeHint(app, udid: udid)
        let relaunch = "xcrun simctl terminate \(udid) \(app.bundleID) && xcrun simctl launch \(udid) \(app.bundleID)"
        return .warning(
            "\(app.bundleID) is running but its accessibility tree is empty; relaunch it, or reboot the simulator if that fails",
            agent: "\(DoctorRules.emptyTreeDetail(app)). \(hint)", try: hint.contains(relaunch) ? relaunch : nil
        )
    }

    /// Reads until the tree has a descendant, `attempts` times at most; when all asked for traits and came back empty, one read without them decides, once per process.
    static func readingFrontmostTree(
        attempts: Int = 5,
        traits request: TraitsRequest? = nil,
        fetch: @MainActor (_ keys: Set<FBAXKeys>) async throws -> Data,
        wait: @MainActor (Duration) async throws -> Void = { duration in try await Task.sleep(for: duration) }
    ) async throws -> Data {
        let traits = request ?? .process
        var latestData: Data?
        for attempt in 0..<attempts {
            let keys = traits.keys
            let data = try await fetch(keys)
            latestData = data
            if try containsAccessibilityDescendant(in: data) {
                traits.readFull(with: keys)
                return data
            }
            if attempt < attempts - 1 {
                try await wait(.milliseconds(50 * (1 << attempt)))
            }
        }
        guard let latestData else {
            throw CLIError(errorDescription: "Accessibility hierarchy could not be serialized.", reason: .treeReadFailed)
        }
        guard traits.triesWithoutTraits else { return latestData }
        let started = ProcessInfo.processInfo.systemUptime
        let plain = try await fetch(accessibilityOutputKeys.subtracting([.traits]))
        let full = try containsAccessibilityDescendant(in: plain)
        traits.triedWithoutTraits(full: full)
        Timings.record("accessibility-without-traits", seconds: ProcessInfo.processInfo.systemUptime - started)
        return full ? plain : latestData
    }

    static func retryingAfterTestManagerRecovery<T>(
        simulatorUDID: String,
        logger: OffsiderLogger,
        dependencies: AccessibilityRecoveryDependencies,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard shouldRecoverTestManagerDaemon(from: error) else {
                throw error
            }
            logger.info().log("Accessibility transport failed; restarting testmanagerd and retrying once")
            try await recoverTestManagerDaemon(
                simulatorUDID: simulatorUDID,
                dependencies: dependencies
            )
            return try await operation()
        }
    }

    static func shouldRecoverTestManagerDaemon(from error: Error) -> Bool {
        let errors = errorChain(from: error)
        let details = errors.flatMap { error in
            [
                error.domain,
                error.localizedDescription,
                error.localizedFailureReason,
                error.localizedRecoverySuggestion,
                error.userInfo[NSDebugDescriptionErrorKey] as? String,
            ].compactMap { $0?.lowercased() }
        }
        if details.contains(where: { normalizedErrorText($0) == "channel disconnected" }) {
            return true
        }
        let identifiesDTX = details.contains(where: { $0.contains("dtx") })
        let identifiesFileDescriptorExhaustion = errors.contains { error in
            error.code == 24
                || error.localizedDescription.localizedCaseInsensitiveContains("errno 24")
                || error.localizedDescription.localizedCaseInsensitiveContains("too many open files")
        }
        return identifiesDTX && identifiesFileDescriptorExhaustion
    }

    private static func normalizedErrorText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func recoverTestManagerDaemon(
        simulatorUDID: String,
        dependencies: AccessibilityRecoveryDependencies
    ) async throws {
        let arguments = [
            "simctl",
            "spawn",
            simulatorUDID,
            "launchctl",
            "kickstart",
            "-k",
            "user/foreground/com.apple.testmanagerd",
        ]
        let status = try await dependencies.runProcess(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments,
            3
        )
        guard status == 0 else {
            throw CLIError(
                errorDescription: "Offsider could not restore accessibility automation for simulator \(simulatorUDID). Restart the simulator and try again.",
                reason: .treeReadFailed
            )
        }
        try await dependencies.wait(.milliseconds(250))
    }

    private static func errorChain(from error: Error) -> [NSError] {
        var errors: [NSError] = []
        var current: NSError? = error as NSError
        var visited: Set<ObjectIdentifier> = []
        while let next = current, visited.insert(ObjectIdentifier(next)).inserted {
            errors.append(next)
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                terminateProcess(process)
                throw error
            }
        }
        if process.isRunning {
            terminateProcess(process)
            throw CLIError(errorDescription: "Offsider timed out while restoring accessibility automation.", reason: .treeReadFailed)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func terminateProcess(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }

    private static func serializedAccessibilityData(from accessibilityElement: FBAccessibilityElement, keys: Set<FBAXKeys>) throws -> Data {
        let response = try accessibilityElement.serialize(
            with: FBAccessibilityRequestOptions(
                nestedFormat: true,
                keys: keys
            )
        )
        return try serializeAccessibilityInfo(response.elements)
    }

    static func containsAccessibilityDescendant(in data: Data) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        let roots: [[String: Any]]
        if let array = object as? [[String: Any]] {
            roots = array
        } else if let root = object as? [String: Any] {
            roots = [root]
        } else {
            return false
        }
        return roots.contains { root in
            guard let children = root["children"] as? [Any] else { return false }
            return !children.isEmpty
        }
    }

    static func isTransientPointFallback(in data: Data, at point: AccessibilityPoint, appPIDs: Set<Int> = []) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        let root: [String: Any]?
        if let dictionary = object as? [String: Any] {
            root = dictionary
        } else if let dictionaries = object as? [[String: Any]], dictionaries.count == 1 {
            root = dictionaries.first
        } else {
            root = nil
        }
        let meaningfulKeys = [
            "AXLabel",
            "AXUniqueId",
            "AXIdentifier",
            "AXValue",
            "title",
            "help",
            "custom_actions",
            "children",
        ]
        guard let root,
              !meaningfulKeys.contains(where: { hasMeaningfulValue(root[$0]) }) else {
            return false
        }
        if !appPIDs.isEmpty, let pid = (root["pid"] as? NSNumber)?.intValue, !appPIDs.contains(pid) {
            return false
        }

        let decoder = JSONDecoder()
        let element: AccessibilityElement
        if let decoded = try? decoder.decode(AccessibilityElement.self, from: data) {
            element = decoded
        } else if let decoded = try? decoder.decode([AccessibilityElement].self, from: data),
                  let first = decoded.first,
                  decoded.count == 1 {
            element = first
        } else {
            return false
        }

        guard element.type == "Group",
              element.role == "AXGroup",
              element.normalizedLabel == nil,
              element.normalizedUniqueId == nil,
              element.normalizedValue == nil,
              element.children?.isEmpty != false,
              let frame = element.frame,
              abs(frame.x) < 1,
              abs(frame.y) < 1 else {
            return false
        }
        let containsPoint = point.x >= frame.x
            && point.x <= frame.x + frame.width
            && point.y >= frame.y
            && point.y <= frame.y + frame.height
        return containsPoint
            && min(frame.width, frame.height) >= 300
            && max(frame.width, frame.height) >= 600
    }

    private static func hasMeaningfulValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            return false
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let array as [Any]:
            return !array.isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        default:
            return true
        }
    }

    static func serializeAccessibilityInfo(_ accessibilityInfo: Any) throws -> Data {
        guard accessibilityInfo is [String: Any] || accessibilityInfo is [[String: Any]] else {
            throw CLIError(errorDescription: "Offsider received an unsupported accessibility response from the simulator.", reason: .treeReadFailed)
        }
        return try JSONSerialization.data(withJSONObject: accessibilityInfo, options: [.prettyPrinted])
    }

    // This key set preserves the legacy public JSON schema; update it only with explicit schema coverage.
    static let accessibilityOutputKeys: Set<FBAXKeys> = [
        .label,
        .frame,
        .value,
        .uniqueID,
        .type,
        .title,
        .frameDict,
        .help,
        .enabled,
        .customActions,
        .role,
        .roleDescription,
        .subrole,
        .contentRequired,
        .pid,
        .traits,
    ]
}

/// Whether simulator reads ask for traits (which carry Selected): some Xcode versions empty the tree for them, so a full read without them turns them off.
@MainActor
final class TraitsRequest {
    static let process = TraitsRequest()

    private(set) var skipsTraits = false
    /// Set by a full read with traits, which proves them safe, or by the one read without them.
    private var settled = false

    var keys: Set<FBAXKeys> {
        skipsTraits ? AccessibilityFetcher.accessibilityOutputKeys.subtracting([.traits]) : AccessibilityFetcher.accessibilityOutputKeys
    }

    var triesWithoutTraits: Bool { !settled }

    func readFull(with keys: Set<FBAXKeys>) {
        if keys.contains(.traits) { settled = true }
    }

    func triedWithoutTraits(full: Bool) {
        settled = true
        skipsTraits = full
    }
}
