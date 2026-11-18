import CoreGraphics
import Foundation
import ImageIO
import OffsiderCore

/// The guard rules this process sees: what a person approved, and the repository's `offsider.guard.json`. Read at most once.
enum GuardSources {
    struct File: Equatable, Sendable {
        let config: GuardConfig
        let path: String
    }

    struct Loaded: Sendable {
        var approvals: GuardApprovals = .empty
        var sealIntact = true
        /// The apps a broken seal still covers.
        var sealedApps: [String] = []
        var file: File?
        /// Why the repository's file cannot be used; input stops until it is fixed or moved aside.
        var problem: String?

        /// True when no rule exists anywhere, so an input command pays nothing more.
        var isEmpty: Bool { approvals.isEmpty && file == nil && sealIntact && problem == nil }

        var apps: [String] { Array(Set(approvals.apps + (file?.config.apps ?? []) + sealedApps)).sorted() }

        func set(for app: String) -> GuardSet {
            GuardSet.resolve(app: app, approval: approvals.entry(app: app), file: file?.config, sealIntact: sealIntact || !sealedApps.contains(app))
        }
    }

    /// A test binds its own rules, or none.
    @TaskLocal static var source: @Sendable () -> Loaded = { Memo.shared.value() }

    static func current() -> Loaded {
        source()
    }

    static func store() -> GuardApprovalStore? {
        UserConfigDirectory.live().map(GuardApprovalStore.init(directory:))
    }

    /// `directory` is where the search for `offsider.guard.json` starts; it stops at the repository root.
    static func load(from directory: String, store: GuardApprovalStore?, seal: any GuardSealing) -> Loaded {
        var loaded = Loaded()
        if let store {
            do {
                let snapshot = try store.load()
                loaded.approvals = snapshot.approvals
                (loaded.sealIntact, loaded.sealedApps) = seal.check(snapshot)
            } catch {
                loaded.sealIntact = false
                loaded.sealedApps = ((try? seal.stored()) ?? nil)?.apps ?? []
            }
        }
        do {
            let found = try ProjectGuide.locate(fileName: GuardConfig.fileName, from: directory)
            loaded.file = File(config: try GuardConfig.parse(Data(found.text.utf8), path: found.path), path: found.path)
        } catch let failure as ProjectGuide.Failure {
            if case .unreadable(let path, let detail) = failure { loaded.problem = "Could not read \(path): \(detail)." }
        } catch {
            loaded.problem = "\(error)"
        }
        return loaded
    }

    /// For a test's scripted device: unless a test binds `source`, this process sees no rules and never reads the real approvals, Keychain or working directory.
    static func defaultToNoRules() {
        Memo.shared.preset(Loaded())
    }

    private final class Memo: @unchecked Sendable {
        static let shared = Memo()
        private let lock = NSLock()
        private var result: Loaded?

        func preset(_ loaded: Loaded) {
            lock.lock()
            defer { lock.unlock() }
            if result == nil { result = loaded }
        }

        func value() -> Loaded {
            lock.lock()
            defer { lock.unlock() }
            if let result { return result }
            let loaded = GuardSources.load(from: FileManager.default.currentDirectoryPath, store: GuardSources.store(), seal: KeychainGuardSeal())
            result = loaded
            return loaded
        }
    }
}

/// Stops an input that would land on a guarded control of the app in front: `never` is refused, `ask` waits for a person at this Mac.
@MainActor
enum AppGuard {
    /// What the gate needs from outside itself; tests bind fakes.
    struct Environment: Sendable {
        /// Asks the person at the Mac; `reason` completes "offsider is trying to ...".
        var confirm: @Sendable (String) async throws -> Void
        /// The saved login Offsider last signed in to `app` on `device`, by name.
        var signedIn: @MainActor @Sendable (_ app: String, _ device: String) -> String?
        /// Whether a person chose this physical device as a test device; simulators and emulators never ask it.
        var isTestDevice: @MainActor @Sendable (DeviceID) -> Bool?

        static let live = Environment(
            confirm: { try await PersonPresence.confirm(reason: $0) },
            signedIn: { app, device in SignInTracker.live().signedInHere(app: app, deviceID: device).map(LoginCredential.displayKey) },
            isTestDevice: { device in
                guard let allowance = CommandScope.current.routes.last(where: { $0.device == device })?.allowance else { return nil }
                return DevicePolicyGate.current.policy().drivesWhole(allowance)
            }
        )
    }

    @TaskLocal static var environment = Environment.live

    /// How old a tree this command already read may be and still stand for the screen, when no input followed it.
    static let freshTree: TimeInterval = 1.5

    /// Throws before anything is sent when `event`, in the backend's input coordinates, would land on a guarded control.
    static func check(_ event: InputEvent, backend: any DeviceBackend, device: DeviceID) async throws {
        let inputs = GuardInput.inputs(of: event)
        guard !inputs.isEmpty else { return }
        try await check(inputs, inputSpace: true, backend: backend, device: device)
    }

    /// `inputs` in the tree's own points when `inputSpace` is false.
    static func check(_ inputs: [GuardInput], inputSpace: Bool, backend: any DeviceBackend, device: DeviceID) async throws {
        for (hit, set) in try await verdicts(inputs, inputSpace: inputSpace, backend: backend, device: device) {
            try await settle(hit, set: set, device: device)
        }
    }

    /// What a tap at `point`, in the tree's points, would meet, for `--dry-run`: nil when it is free. Asks nobody.
    static func preview(at point: UIPoint, backend: any DeviceBackend, device: DeviceID) async throws -> String? {
        guard let (hit, set) = try await verdicts([.press(point)], inputSpace: false, backend: backend, device: device).first else { return nil }
        let rule = "the rule \"\(hit.rule.name)\" in \(set.app)"
        return hit.action == .never ? "Guarded by \(rule): an agent never taps it." : "Guarded by \(rule): a person approves the tap at the Mac first."
    }

    /// Every guarded control the inputs would land on, with the rules that guard it; throws when the rules themselves cannot be trusted.
    private static func verdicts(_ inputs: [GuardInput], inputSpace: Bool, backend: any DeviceBackend, device: DeviceID) async throws -> [(GuardHit, GuardSet)] {
        let loaded = GuardSources.current()
        guard !loaded.isEmpty, !inputs.isEmpty else { return [] }
        if let problem = loaded.problem {
            throw CLIError(errorDescription: "\(problem) Offsider sent nothing. Fix the file, or move it aside.", reason: .usage)
        }
        return try await Timings.measure("guard") {
            let tree = try await tree(backend: backend, device: device)
            // Every app with an element on screen is judged, as two can share it; one Offsider cannot name brings every app's rules.
            let present = appsOnScreen(tree)
            let sets = loaded.apps.filter { present?.contains($0) ?? true }.map(loaded.set(for:)).filter { $0.state != .missing }
            guard !sets.isEmpty else { return [] }
            var points = inputs
            if inputSpace, inputs.contains(where: { $0 != .activate }) {
                let probes = GuardPointMap.probes.map { (x: $0.x, y: $0.y) }
                let mapped = try await backend.deviceCoordinates(for: probes, tree: tree, on: device).map { UIPoint(x: $0.x, y: $0.y) }
                guard let map = GuardPointMap(mapped: mapped) else {
                    throw CLIError(errorDescription: "Offsider could not place this input on the screen to check it against the guard rules for \(sets.map(\.app).joined(separator: ", ")), so it sent nothing. Tap by --id or --label instead.", reason: .commandFailed)
                }
                points = inputs.map { $0.mapped(map.screenPoint) }
            }
            var found: [(GuardHit, GuardSet)] = []
            for set in sets {
                if set.state == .changed {
                    throw CLIError(
                        errorDescription: "The approved guard rules for \(set.app) were changed outside Offsider, so Offsider sent nothing. A person approves them again with `\(approveCommand(set.app))` in their own terminal.",
                        reason: .guardedControl, hint: approveCommand(set.app), ask: "Can you run `\(approveCommand(set.app))` in your terminal?"
                    )
                }
                for input in points {
                    guard var hit = GuardJudge.verdict(rules: set.rules, tree: tree, input: input) else { continue }
                    if hit.unsure, case .press(let point) = input, let texts = await textNear(point, tree: tree, backend: backend, device: device) {
                        guard let read = GuardJudge.verdict(rules: set.rules, tree: tree, input: input, textNear: { _ in texts }) else { continue }
                        hit = read
                    }
                    found.append((hit, set))
                }
            }
            return found
        }
    }

    static func approveCommand(_ app: String) -> String {
        GuardReport.approveCommand(app: app)
    }

    /// The apps with an element in the tree: Android packages, or the bundle ids of iOS application elements. Nil when one cannot be named.
    static func appsOnScreen(_ tree: UITree) -> Set<String>? {
        var apps: Set<String> = []
        for node in tree.roots.flatMap({ $0.flattened() }) {
            switch node.native {
            case .android(let attributes):
                if let package = attributes.package, !package.isEmpty { apps.insert(package) }
            case .ios(let attributes) where node.role == .application:
                guard let app = attributes.bundleID ?? attributes.pid.flatMap(ForegroundAppLookup.bundleIdentifier(pid:)) else { return nil }
                apps.insert(app)
            case .ios:
                break
            }
        }
        return apps.isEmpty ? nil : apps
    }

    /// Full trees a backend read for its own ends, by device id, so the guard does not read the screen twice for one tap.
    private static var noted: [String: (tree: UITree, at: Date)] = [:]

    /// One command's notes never serve another's: the key carries the command's own ledger.
    private static func noteKey(_ device: DeviceID) -> String {
        "\(ObjectIdentifier(DeviceActivityLedger.current).hashValue) \(device.rawValue)"
    }

    /// Called by a backend that read a whole tree without recording it, as a simulator does to place a coordinate.
    static func note(_ tree: UITree, on device: DeviceID) {
        guard !GuardSources.current().isEmpty else { return }
        noted[noteKey(device)] = (tree, DeviceActivityLedger.current.now())
    }

    /// The tree this command read a moment ago when nothing was sent since, else a new read.
    private static func tree(backend: any DeviceBackend, device: DeviceID) async throws -> UITree {
        let ledger = DeviceActivityLedger.current
        let activity = ledger.activity(for: device)
        var candidates: [(tree: UITree, at: Date)] = []
        if let tree = activity?.tree, let at = activity?.treeReadAt { candidates.append((tree, at)) }
        if let kept = noted[noteKey(device)] { candidates.append(kept) }
        let now = ledger.now()
        if let newest = candidates.max(by: { $0.at < $1.at }), now.timeIntervalSince(newest.at) < freshTree, activity?.lastInputAt.map({ $0 < newest.at }) ?? true {
            return newest.tree
        }
        return try await DeviceWatchdog().guardingInputRead(of: device) { try await backend.accessibilityTree(for: device) }
    }

    /// The words drawn around `point`; nil when the screen could not be captured or read, so a person decides.
    private static func textNear(_ point: UIPoint, tree: UITree, backend: any DeviceBackend, device: DeviceID) async -> [String]? {
        guard let viewport = tree.viewport, let png = try? await backend.screenshotPNG(for: device),
              let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              abs(Double(image.width) / Double(image.height) - viewport.width / viewport.height) < 0.02 else { return nil }
        return await ScreenTextReader.lines(in: png, region: UIFrame(x: point.x - 120, y: point.y - 36, width: 240, height: 72), viewport: viewport)
    }

    private static func settle(_ hit: GuardHit, set: GuardSet, device: DeviceID) async throws {
        let environment = Self.environment
        // The label as output may show it: what `offsider.mask.json` hides stays hidden here too.
        let label = hit.control.map { OutputMasks.current.mask.shownLabel($0, id: hit.controlID) }
        let control = label.map { TerminalText.quoted($0) } ?? "this spot"
        let what = hit.unsure
            ? "Offsider cannot tell what is at this point on a screen the rule \"\(hit.rule.name)\" guards in \(set.app)"
            : "\(control) in \(set.app) is guarded by the rule \"\(hit.rule.name)\""
        let yours = "Can you tap \(control) on \(PersonAsk.devicePlaceholder) yourself?"
        guard hit.action == .ask else {
            throw CLIError(
                errorDescription: "\(what), which an agent never taps. Offsider sent nothing. Leave it, or tell the user it is theirs to tap.",
                reason: .guardedControl
            )
        }
        if environment.isTestDevice(device) == false {
            throw CLIError(
                errorDescription: "\(what), which asks a person first, and on a phone that is not a test device the tap is theirs. Offsider sent nothing.",
                reason: .guardedControl, ask: yours
            )
        }
        let user = environment.signedIn(set.app, device.rawValue)
        guard set.mayAsk(user: user) else {
            let why = user.map { "the saved login \($0) is not one these rules ask for" } ?? "Offsider did not sign this account in with a saved login"
            throw CLIError(
                errorDescription: "\(what), which asks a person first, and \(why), so the tap is theirs. Offsider sent nothing.",
                reason: .guardedControl, ask: yours
            )
        }
        let reason = "tap \(label.map { "“\(PromptScreen.label($0, cap: 40))”" } ?? "an unreadable spot") (\(hit.rule.name)) in \(set.app), signed in as \(user ?? "a saved login")"
        do {
            try await environment.confirm(reason)
        } catch {
            throw CLIError(
                errorDescription: "\(what), which asks a person first, and nobody approved it at this Mac. Offsider sent nothing.",
                reason: .personRequired, ask: "Can you approve the tap on \(control) with Touch ID at the Mac, or tap it on \(PersonAsk.devicePlaceholder) yourself?"
            )
        }
        Console.current.notice(Notice(kind: .note, text: "A person approved \(control) (\(hit.rule.name))", label: "Try"))
    }
}
