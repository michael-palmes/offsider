import ArgumentParser
import Foundation
import OffsiderAndroid
import OffsiderCore

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the host and, with --device, a simulator, Android emulator or USB phone for problems that stop Offsider input or screen reads."
    )

    @OptionGroup
    var deviceOption: OptionalDeviceOption

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @Flag(name: .customLong("fix"), help: "Apply safe, repeatable fixes, then check again.")
    var fix = false

    func run() async throws {
        let report: DoctorReport
        if let id = deviceOption.id, DeviceIDClassifier.classify(id).platform == .android {
            report = await androidReport(id)
        } else {
            report = await hostAndSimulatorReport()
        }
        try write(report)
        if report.exitCode != .success {
            throw ExitCode(report.exitCode.rawValue)
        }
    }

    /// Xcode, simulator and HID checks, then Android host checks (skipped when no SDK is installed).
    private func hostAndSimulatorReport() async -> DoctorReport {
        let udid = deviceOption.id.map(Self.canonicalUDID)
        let runner = DoctorRunner(
            udid: udid,
            environment: ProcessInfo.processInfo.environment,
            logger: OffsiderLogger()
        )
        let android = AndroidDoctorProbe(host: .cli())
        var result = await runner.run()
        var facts = await android.run(deviceID: nil).host
        var fixes: [DoctorFixResult] = []
        if fix {
            fixes = await DoctorFixes.apply(after: result, udid: udid)
            if case .found = facts.sdk {
                fixes.append(await android.startAdbServerIfAbsent())
            }
            result = await runner.run()
            facts = await android.run(deviceID: nil).host
        }
        let device = udid.map { udid in
            DoctorDevice(id: udid, platform: "ios", name: result.booted.first { $0.udid == udid }?.name, kind: "simulator")
        }
        return DoctorReport(
            offsiderVersion: VERSION,
            udid: udid,
            device: device,
            xcode: result.xcode,
            booted: result.booted,
            android: AndroidDoctorRules.summary(facts, device: nil),
            checks: result.checks + AndroidDoctorRules.hostChecks(facts, deviceNamed: false),
            fixes: fixes
        )
    }

    /// Android host and device checks only: Xcode and simulator state cannot affect an Android session.
    private func androidReport(_ id: String) async -> DoctorReport {
        let probe = AndroidDoctorProbe(host: .cli())
        var facts = await probe.run(deviceID: id)
        var fixes: [DoctorFixResult] = []
        if fix {
            fixes = [await probe.startAdbServerIfAbsent()]
            facts = await probe.run(deviceID: id)
        }
        let serial = facts.device?.serial ?? id
        let kind: String? = facts.device.flatMap { device in
            device.isPhysical ? "physical" : device.serial.map { DeviceIDClassifier.classify($0).platform == .android ? "emulator" : "other" }
        }
        return DoctorReport(
            offsiderVersion: VERSION,
            udid: nil,
            device: DoctorDevice(id: serial, platform: "android", name: facts.device?.avdName ?? facts.device?.model, kind: kind),
            xcode: XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil),
            booted: [],
            android: AndroidDoctorRules.summary(facts.host, device: facts.device),
            checks: AndroidDoctorRules.hostChecks(facts.host, deviceNamed: true)
                + AndroidDoctorRules.deviceChecks(facts.device, hostBlocker: AndroidDoctorRules.hostBlocker(facts.host)),
            fixes: fixes
        )
    }

    private static func canonicalUDID(_ raw: String) -> String {
        if case .iosSimulator(let udid) = DeviceIDClassifier.classify(raw) {
            return udid
        }
        return raw
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
