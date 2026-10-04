import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("describe-ui --diff")
@MainActor
struct DescribeUIDiffTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static let steady = ["A", "B", "C"].enumerated().map { index, label in
        FakeUI.node(.text, id: label.lowercased(), label: label, frame: FakeUI.frame(20, 160 + Double(index) * 50, 350, 44))
    }
    static let closed = FakeUI.tree([FakeUI.node(.button, id: "open", label: "Open", frame: FakeUI.frame(20, 100, 350, 44))] + steady)
    static let opened = FakeUI.tree([FakeUI.node(.button, id: "open", label: "Open", frame: FakeUI.frame(20, 100, 350, 44))] + steady + [
        FakeUI.node(.header, id: "sheet-title", label: "Filters", frame: FakeUI.frame(20, 400, 350, 30)),
        FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(20, 600, 350, 44)),
    ])

    private static func describe(_ arguments: [String], on backend: FakeDeviceBackend) async throws -> String {
        let route = DeviceRouter.Route(backend: backend, device: device)
        let output = try await DescribeUI.parse(arguments + ["--device", device.rawValue]).describe(on: route)
        await TreeCache.commit(command: "describe-ui", effect: .read, claimed: [], backends: [backend])
        DeviceActivityLedger.current.reset()
        return output
    }

    @Test("--diff with no earlier tree prints the full output and says so")
    func noEarlierTree() async throws {
        let fixture = try TreeCacheFixture()
        let output = try await fixture.run { try await Self.describe(["--diff"], on: FakeDeviceBackend(trees: [Self.closed])) }
        #expect(output.hasPrefix("# ios fake-device\n# no earlier tree for this device; full output follows\napplication \"Playground\" (0,0 402x874)\n  button \"Open\" id=open (20,100 350x44)\n"))
    }

    @Test("--diff prints unchanged with the command and age")
    func unchanged() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.closed])
        let output = try await fixture.run {
            _ = try await Self.describe(["--summary"], on: backend)
            fixture.now += 1.25
            return try await Self.describe(["--diff"], on: backend)
        }
        #expect(output == "# ios fake-device\n# unchanged since describe-ui 1250 ms ago (\(TreeDiff.hash(Self.closed)))\n")
    }

    @Test("--diff after a tap shows what the tap changed")
    func afterTap() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.closed, Self.opened], advanceTreeOnInput: true)
        let output = try await fixture.run {
            try await Tap.parse(["--id", "open", "--no-settle", "--device", Self.device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
            await TreeCache.commit(command: "tap", effect: .input, claimed: [], backends: [backend])
            DeviceActivityLedger.current.reset()
            fixture.now += 0.84
            return try await Self.describe(["--diff"], on: backend)
        }
        #expect(output == """
        # ios fake-device
        # changes since tap 840 ms ago: 2 added, 0 changed, 0 removed
        added header "Filters" id=sheet-title (20,400 350x30)
        added button "Apply" id=apply (20,600 350x44)

        """)
    }

    @Test("--diff is refused with JSON, compact and --point", arguments: [["--format", "json"], ["--format", "ndjson"], ["--compact"], ["--point", "10,10"]])
    func refused(extra: [String]) {
        #expect(throws: (any Error).self) {
            _ = try DescribeUI.parse(["--diff", "--device", Self.device.rawValue] + extra)
        }
    }

    @Test("--diff errors are text, not the JSON envelope")
    func diffIsText() throws {
        #expect(try !DescribeUI.parse(["--diff", "--device", Self.device.rawValue]).wantsJSON)
    }
}

@Suite("Command effects")
struct CommandEffectTests {
    private static func paths(_ commands: [any ParsableCommand.Type], prefix: String = "") -> [String] {
        commands.flatMap { command -> [String] in
            let name = prefix + command._commandName
            let children = command.configuration.subcommands
            return children.isEmpty ? [name] : paths(children, prefix: name + " ")
        }
    }

    @Test("every subcommand and batch step kind is classified as input, read or neither")
    func everyCommandClassified() {
        let commands = Self.paths(OffsiderCommand.configuration.subcommands)
        #expect(Set(commands) == Set(CommandEffect.table.keys), "unclassified: \(Set(commands).subtracting(CommandEffect.table.keys))")
        let steps = ["sleep"] + [BatchStepKind.tap, .swipe, .gesture, .touch, .type, .button, .key, .keySequence, .keyCombo, .wait, .assert, .screenshot, .describeUI].map(\.rawValue)
        #expect(Set(steps) == Set(CommandEffect.batchSteps.keys))
        for step in steps where step != "sleep" {
            #expect((CommandEffect.batchSteps[step] == .input) == BatchStepKind(rawValue: step)!.mayChangeScreen, "\(step)")
        }
    }
}
