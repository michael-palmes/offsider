import ArgumentParser
import Foundation
import OffsiderCore

/// `--screenshot-at` and `--output` on swipe and drag: masked screenshots while the finger rests at the end, before it lifts.
struct HoldScreenshotOptions: ParsableArguments {
    static let maxShots = 10
    static let maxOffset = 10_000
    static let batchMessage = "Batch steps do not take --screenshot-at or --output. Run the swipe or drag on its own to capture during its hold."

    @Option(name: .customLong("screenshot-at"), help: ArgumentHelp("Take a masked screenshot this many milliseconds after the finger comes to rest at the end, before it lifts; from 0 to 10000, up to 10 times.", valueName: "ms"))
    var offsets: [Int] = []

    @Option(help: ArgumentHelp("With --screenshot-at, the image path or a folder for generated names; several screenshots to one path are numbered -1, -2.", valueName: "path"))
    var output: String?

    var isRequested: Bool { !offsets.isEmpty }

    /// The offsets in the order they are taken.
    var ordered: [Int] { offsets.sorted() }

    /// Usage problems, given the command's own --hold-end when one was passed.
    func check(holdEnd: Int?) throws {
        if output != nil, offsets.isEmpty {
            throw ValidationError("--output applies to --screenshot-at only.")
        }
        guard offsets.count <= Self.maxShots else {
            throw ValidationError("--screenshot-at takes at most \(Self.maxShots) screenshots; got \(offsets.count).")
        }
        if let wrong = offsets.first(where: { !(0...Self.maxOffset).contains($0) }) {
            throw ValidationError("--screenshot-at must be from 0 to \(Self.maxOffset); got \(wrong).")
        }
        if let holdEnd, let last = ordered.last, last > holdEnd {
            throw ValidationError("--screenshot-at \(last) comes after --hold-end \(holdEnd). Raise --hold-end to \(last), or leave it out to hold until the last screenshot.")
        }
    }

    /// The end hold in milliseconds: --hold-end when passed, else `fallback`, stretched to reach the last screenshot.
    func holdEnd(given: Int?, fallback: Int) -> Int {
        given ?? max(fallback, ordered.last ?? 0)
    }

    /// Where screenshot `index` goes: --output for one screenshot or a folder, else numbered before the extension; nil for the default name.
    func outputPath(for index: Int) -> String? {
        guard let output, offsets.count > 1, !Self.isFolder(output) else { return output }
        let ext = (output as NSString).pathExtension
        let base = ext.isEmpty ? output : String(output.dropLast(ext.count + 1))
        return ext.isEmpty ? "\(base)-\(index + 1)" : "\(base)-\(index + 1).\(ext)"
    }

    /// An existing folder, or a path ending in `/`, which takes generated names.
    static func isFolder(_ path: String) -> Bool {
        if path.hasSuffix("/") { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Before anything is sent: a person confirms unmasked password fields for an agent, and a folder ending in `/` is made.
    func prepare(command: String) async throws {
        if !Screenshot.masksSecure(flag: nil) { try await UnmaskedConsent.confirm(command: command) }
        if let output, output.hasSuffix("/") {
            try FileManager.default.createDirectory(atPath: (output as NSString).expandingTildeInPath, withIntermediateDirectories: true)
        }
    }

    /// Sends `press`, takes each screenshot while the finger rests at its end, then sends `lift`; each screenshot and the hold go into `details`.
    @MainActor
    func perform(press: InputEvent, lift: InputEvent, holdEnd: Int, on route: DeviceRouter.Route, details: InputDetails) async throws {
        let shots = try ordered.indices.map { index in
            try Screenshot.parse(["--device", route.device.rawValue] + (outputPath(for: index).map { ["--output", $0] } ?? []))
        }
        guard let first = shots.first else { return }
        let masks = first.masksWithRunDefaults(try first.maskPlan())
        let standing = try MaskConfigs.current()?.config.plan
        if (standing.map(masks.union) ?? masks).needsTree, let reader = route.backend as? any MaskTreeReading {
            try await reader.prepareMaskTree(for: route.device)
        }
        let session = try await route.backend.openTrackedSession(for: route.device)
        let capture = HoldCapture(offsets: ordered, holdEnd: holdEnd)
        do {
            details.holdMs = try await capture.perform(press: press, lift: lift, on: session) { index in
                try await Console.current.progress("Capturing the screen") {
                    try await shots[index].take(try shots[index].request(), on: route, masks: masks)
                }
            } taken: { details.screenshots.append($0) }
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    /// A note when the screenshots kept the finger down past the --hold-end the caller passed.
    static func noteOverrun(held: Int?, asked: Int?) {
        guard let held, let asked, held > asked + HoldCapture.overrunMilliseconds else { return }
        Console.current.notice(.note(
            "Held \(Self.seconds(held)), not \(Self.seconds(asked)), to take the screenshots",
            agent: "the finger rested \(held) ms, not --hold-end \(asked) ms, while the screenshots were taken (holdMs)."
        ))
    }

    private static func seconds(_ milliseconds: Int) -> String {
        (Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(0...1))) + " s"
    }
}

/// A gesture sent in parts around its screenshots: the press, a screenshot at each offset while the finger rests, then the lift.
@MainActor
struct HoldCapture {
    /// A hold this much past --hold-end is worth a note.
    nonisolated static let overrunMilliseconds = 100

    /// Milliseconds after the finger comes to rest, ascending.
    let offsets: [Int]
    let holdEnd: Int
    var uptime: () -> Duration = { .seconds(ProcessInfo.processInfo.systemUptime) }

    /// Returns how long the finger rested before the lift was sent; after a failure past the press, lifts before throwing.
    func perform(
        press: InputEvent,
        lift: InputEvent,
        on session: any InputSession,
        shoot: (Int) async throws -> ScreenshotReport,
        taken: (HeldScreenshot) -> Void
    ) async throws -> Int {
        try await session.perform(press)
        let rested = uptime()
        func elapsed() -> Int { Int((uptime() - rested) / .milliseconds(1)) }
        do {
            for (index, at) in offsets.enumerated() {
                let wait = at - elapsed()
                // Waits go through the session, so a resting finger keeps reporting where it is.
                if wait > 0 { try await session.perform(.delay(Double(wait) / 1000)) }
                let start = elapsed()
                let report = try await shoot(index)
                taken(HeldScreenshot(atMs: at, startMs: start, endMs: elapsed(), report: report))
            }
            let rest = holdEnd - elapsed()
            let held = max(holdEnd, elapsed())
            try await session.perform(rest > 0 ? .composite([.delay(Double(rest) / 1000), lift]) : lift)
            return held
        } catch {
            try? await session.perform(lift)
            throw error
        }
    }
}
