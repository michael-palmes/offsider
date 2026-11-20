import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// No near-miss suggestion names the text of a password field, a revealed one or a masked value; the text here is made up.
@Suite("Near misses never name a hidden value")
@MainActor
struct NearMissSecretTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let revealedEntry = SecureFieldRecord.Entry(id: "password-field", frame: FakeUI.frame(16, 270, 361, 44))
    static let revealedText = "plum-7731-otter"
    static let secureText = "fig-2468-heron"
    static let maskedText = "kiwi-5150-wren"

    static func screen() -> UITree {
        FakeUI.tree([
            FakeUI.node(.textField, id: "password-field", label: "Password", value: revealedText, frame: revealedEntry.frame),
            FakeUI.node(.secureTextField, id: "pin-field", label: "PIN", value: secureText, frame: FakeUI.frame(16, 330, 361, 44)),
            FakeUI.node(.text, id: "member-code", label: "Member code", value: maskedText, frame: FakeUI.frame(16, 390, 361, 44)),
            FakeUI.node(.text, id: "plan-name", label: "Plan", value: "Standard yearly", frame: FakeUI.frame(16, 450, 361, 44)),
        ])
    }

    static var route: DeviceRouter.Route {
        DeviceRouter.Route(backend: FakeDeviceBackend(trees: [screen()]), device: device)
    }

    /// The masks a command learns on its route: the revealed field from the tree cache and `member-code` from a mask file.
    static func masked<T>(_ body: () async throws -> T) async rethrows -> T {
        let record = SecureFieldRecord(platform: .ios, device: device.rawValue, writtenAt: Date(), bootMarker: nil, entries: [revealedEntry])
        let mask = TreeValueMask(ids: ["member-code"], revealed: RevealedSecrets(record))
        return try await OutputMasks.$current.withValue(OutputMasks { mask }) { try await body() }
    }

    static func hidesEverySecret(_ text: String) -> Bool {
        [revealedText, secureText, maskedText].allSatisfy { !text.contains($0) }
    }

    static func printed(_ run: (Console) async throws -> Void) async -> String {
        let capture = ConsoleCapture()
        try? await run(AgentOutputTests.agentConsole(capture))
        return capture.out + capture.err
    }

    static let probes = ["plum-7731", "otter", "fig-2468", "heron", "kiwi-5150", "wren"]

    @Test("a selector miss (tap, type and every selector command) never suggests a hidden value", arguments: probes)
    func resolverSuggestion(probe: String) async throws {
        let message = await Self.masked { () -> String in
            do {
                _ = try AccessibilityTargetResolver.resolveTap(roots: Self.screen().roots, query: .value(probe))
                return "matched"
            } catch let error as ElementResolutionError {
                return error.userFacingDescription + "\(error.candidates)"
            } catch {
                return "\(error)"
            }
        }
        #expect(message.contains("No accessibility element matched --value"), "\(message)")
        #expect(Self.hidesEverySecret(message), "\(message)")
    }

    @Test("assert --value's near miss, in text and JSON, never names a hidden value", arguments: probes)
    func assertNearMiss(probe: String) async throws {
        for json in [false, true] {
            let command = try Assert.parse(["--value", probe, "--device", Self.device.rawValue] + (json ? ["--json"] : []))
            let shown = try await Self.masked {
                let outcome = try await command.evaluate(on: Self.route, logger: OffsiderLogger())
                #expect(!outcome.met)
                return (outcome.reason ?? "") + (await Self.printed { try await command.show(outcome, on: Self.route, console: $0) })
            }
            #expect(Self.hidesEverySecret(shown), "\(shown)")
        }
    }

    @Test("wait --value's last near miss never names a hidden value", arguments: probes)
    func waitNearMiss(probe: String) async throws {
        let command = try Wait.parse(["--value", probe, "--timeout", "0", "--device", Self.device.rawValue])
        let shown = try await Self.masked {
            let outcome = try await command.evaluate(on: Self.route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
            #expect(!outcome.met)
            return await Self.printed { try await command.show(outcome, on: Self.route, console: $0) }
        }
        #expect(Self.hidesEverySecret(shown), "\(shown)")
    }

    @Test("--has-value on a password field is refused, never its text")
    func secureHasValueRefused() async throws {
        let command = try Assert.parse(["--id", "pin-field", "--has-value", "nope", "--device", Self.device.rawValue])
        let refusal = await #expect(throws: SelectorRefusal.self) { try await Self.masked { _ = try await command.evaluate(on: Self.route, logger: OffsiderLogger()) } }
        #expect(refusal?.reason == .secureFieldArgument)
        #expect(Self.hidesEverySecret(refusal?.failureMessage ?? ""))
    }

    @Test("a route learns the device's revealed fields from the tree cache, so a near miss on it hides their text")
    func routeLearnsRevealed() async throws {
        let fixture = try TreeCacheFixture()
        let record = SecureFieldRecord(platform: .ios, device: Self.device.rawValue, writtenAt: fixture.now, bootMarker: nil, entries: [Self.revealedEntry])
        try OffsiderPrivateDirectory.writeAtomically(
            record.encoded(), named: SecureFieldRecord.fileName(platform: .ios, device: Self.device.rawValue), in: fixture.directory
        )
        let message = try await fixture.run {
            try await OutputMasks.$current.withValue(OutputMasks { .none }) { () -> String in
                await DeviceRouter.learnMasks(for: Self.route)
                return Self.missMessage(.value("plum-7731"), roots: Self.screen().roots)
            }
        }
        #expect(!message.contains(Self.revealedText), "\(message)")
    }

    @Test("a field read as a password field earlier in the same command stays hidden once a toggle reveals it")
    func revealedWithinCommand() {
        var shown = Self.screen()
        shown.roots = shown.roots.map { root in
            var copy = root
            copy.children = root.children.map { node in
                var node = node
                if node.id == "pin-field" { node.role = .textField }
                return node
            }
            return copy
        }
        let message = OutputMasks.$current.withValue(OutputMasks { .none }) { () -> String in
            OutputMasks.current.note(Self.screen())
            return Self.missMessage(.value("fig-2468"), roots: shown.roots)
        }
        #expect(message.contains("No accessibility element matched --value"), "\(message)")
        #expect(!message.contains(Self.secureText), "\(message)")
    }

    static func missMessage(_ query: AccessibilityQuery, roots: [UINode]) -> String {
        do {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: query)
            return "matched"
        } catch {
            return (error as? ElementResolutionError)?.userFacingDescription ?? "\(error)"
        }
    }

    @Test("a value nothing hides is still suggested")
    func plainValueSuggested() async throws {
        let message = await Self.masked { () -> String in
            do {
                _ = try AccessibilityTargetResolver.resolveTap(roots: Self.screen().roots, query: .value("Standard"))
                return "matched"
            } catch {
                return (error as? ElementResolutionError)?.userFacingDescription ?? "\(error)"
            }
        }
        #expect(message.contains(#"Did you mean "Standard yearly""#), "\(message)")
    }
}
