import ArgumentParser
import Foundation
import OffsiderCore

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the host and, with --udid, a simulator for problems that stop Offsider input or accessibility reads."
    )

    @Option(name: .customLong("udid"), help: "Also check this simulator.")
    var simulatorUDID: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @Flag(name: .customLong("fix"), help: "Apply safe, repeatable fixes, then check again.")
    var fix = false

    func run() async throws {
        let runner = DoctorRunner(
            udid: simulatorUDID,
            environment: ProcessInfo.processInfo.environment,
            logger: OffsiderLogger()
        )
        var result = await runner.run()
        var fixes: [DoctorFixResult] = []
        if fix {
            fixes = await DoctorFixes.apply(after: result, udid: simulatorUDID)
            result = await runner.run()
        }
        let report = DoctorReport(
            offsiderVersion: VERSION,
            udid: simulatorUDID,
            xcode: result.xcode,
            booted: result.booted,
            checks: result.checks,
            fixes: fixes
        )
        try write(report)
        if report.exitCode != .success {
            throw ExitCode(report.exitCode.rawValue)
        }
    }

    private func write(_ report: DoctorReport) throws {
        let human = Data(DoctorRenderer.render(report).utf8)
        if json {
            FileHandle.standardError.write(human)
            FileHandle.standardOutput.write(try report.jsonData() + Data("\n".utf8))
        } else {
            FileHandle.standardOutput.write(human)
        }
    }
}
