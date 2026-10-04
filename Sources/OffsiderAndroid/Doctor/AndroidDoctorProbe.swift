import Foundation
import OffsiderCore

/// Read-only Android checks: never starts or kills the adb server, never writes a setting, never adds or removes a reverse.
@MainActor
public struct AndroidDoctorProbe {
    nonisolated static let deviceScript = "getprop ro.product.cpu.abi; settings get secure accessibility_enabled; "
        + "settings get secure enabled_accessibility_services; pidof \(HelperLauncher.processName)"
    /// The API level and release first (a phone's device-list row has neither), then the emulator script, whose `pidof` may print nothing.
    nonisolated static let phoneScript = "getprop ro.build.version.sdk; getprop ro.build.version.release; " + deviceScript

    let host: AndroidHost

    public nonisolated init(host: AndroidHost) {
        self.host = host
    }

    /// Host facts, then, with `deviceID` and a reachable server, that device's facts with the helper probe last.
    public func run(deviceID: String?) async -> (host: AndroidHostFacts, device: AndroidDeviceFacts?) {
        let (facts, client) = await hostFacts()
        guard let deviceID, let client, AndroidDoctorRules.hostBlocker(facts) == nil else {
            return (facts, nil)
        }
        return (facts, await deviceFacts(deviceID, client: client))
    }

    // MARK: Host

    func hostFacts() async -> (AndroidHostFacts, AdbClient?) {
        let bundle: HelperBundleFact
        do {
            bundle = .ok(version: try host.helperDex().version, protocolVersion: HelperDex.protocolVersion)
        } catch {
            bundle = .problem(String(describing: error))
        }
        let sdk: AndroidSDK
        do {
            sdk = try AndroidSDK.locate(host: host)
        } catch let error as AndroidError where error.kind == .sdkVariableWithoutAdb {
            let variable = host.variable("ANDROID_HOME") != nil ? "ANDROID_HOME" : "ANDROID_SDK_ROOT"
            return (AndroidHostFacts(sdk: .variableWithoutAdb(variable: variable, message: error.message), helperBundle: bundle), nil)
        } catch {
            return (AndroidHostFacts(sdk: .notFound, helperBundle: bundle), nil)
        }
        var facts = AndroidHostFacts(
            sdk: .found(root: sdk.root.path, source: Self.sourceName(sdk.source), adbPath: sdk.adb.path),
            adb: await adbBinary(sdk.adb),
            emulatorRevision: emulatorRevision(sdk),
            helperBundle: bundle
        )
        let endpoint: LoopbackEndpoint
        do {
            endpoint = try LoopbackEndpoint.adbServer(environment: host.environment)
        } catch {
            facts.server = .badSetting((error as? AndroidError)?.message ?? String(describing: error))
            return (facts, nil)
        }
        let client = AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing)
        do {
            facts.server = .answering(endpoint: endpoint.description, version: try await client.serverVersion())
        } catch let error as AndroidError where error.kind == .adbServerNotRunning {
            facts.server = .notRunning(endpoint: endpoint.description)
            return (facts, nil)
        } catch {
            facts.server = .noAnswer(endpoint: endpoint.description, detail: (error as? AndroidError)?.message ?? String(describing: error))
            return (facts, nil)
        }
        do {
            facts.mdns = AndroidDoctorRules.mdnsFact(fromCheckReply: try await client.mdnsCheck())
        } catch {
            facts.mdns = .unknown((error as? AndroidError)?.message ?? String(describing: error))
        }
        facts.devices = try? await deviceRows(client)
        return (facts, client)
    }

    static func sourceName(_ source: AndroidSDK.Source) -> String {
        switch source {
        case .androidHome: return "ANDROID_HOME"
        case .androidSDKRoot: return "ANDROID_SDK_ROOT"
        case .defaultLocation: return "default location"
        case .adbOnPath: return "adb on PATH"
        }
    }

    private func adbBinary(_ adb: URL) async -> AdbBinaryFact {
        do {
            let result = try await host.processes.capture(executable: adb.path, arguments: ["version"], environment: host.environment, timeout: 5)
            guard result.status == 0 else {
                return .failed(HelperLauncher.firstLine(result.stderr) ?? "it exited with status \(result.status)")
            }
            return Self.adbVersion(result.stdout)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// `Android Debug Bridge version 1.0.41` then `Version 37.0.0-14910828`.
    static func adbVersion(_ output: String) -> AdbBinaryFact {
        var release: String?
        var protocolVersion: Int?
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Android Debug Bridge version ") {
                protocolVersion = text.split(separator: ".").last.flatMap { Int($0) }
            } else if text.hasPrefix("Version ") {
                release = String(text.dropFirst("Version ".count))
            }
        }
        guard let release else { return .failed("adb version printed no version") }
        return .version(release, protocolVersion: protocolVersion)
    }

    private func emulatorRevision(_ sdk: AndroidSDK) -> String? {
        let path = sdk.root.appendingPathComponent("emulator/source.properties").path
        guard let data = host.files.contents(atPath: path) else { return nil }
        return IniFile.parse(String(decoding: data, as: UTF8.self))["Pkg.Revision"]
    }

    /// adb's rows with AVD names from discovery files only, so no other device is queried.
    private func deviceRows(_ client: AdbClient) async throws -> [AndroidDeviceRow] {
        let discoveries = EmulatorDiscovery.live(host: host)
        return try await client.devices().map { entry in
            let port = entry.consolePort
            let avd = port.flatMap { port in discoveries.first { $0.consolePort == port }?.avdID }
            return AndroidDeviceRow(
                serial: entry.serial,
                kind: port == nil ? "other" : "emulator",
                state: Self.stateName(entry.state),
                avd: avd,
                apiLevel: nil
            )
        }
    }

    static func stateName(_ state: AdbDeviceState) -> String {
        switch state {
        case .device: return "Online"
        case .offline: return "Offline"
        case .unauthorized: return "Unauthorised"
        case .other(let text): return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    // MARK: Device

    func deviceFacts(_ id: String, client: AdbClient) async -> AndroidDeviceFacts {
        let directory = AndroidDeviceDirectory(client: client, host: host)
        let serial: String
        switch DeviceIDClassifier.classify(id) {
        case .androidSerial:
            serial = id
        default:
            do {
                serial = try await directory.resolve(name: id)
            } catch {
                return AndroidDeviceFacts(id: id, state: .notFound(Self.message(error)))
            }
        }
        guard case .androidSerial = DeviceIDClassifier.classify(serial) else {
            return await phoneFacts(id, serial: serial, directory: directory, client: client)
        }
        let emulator: RunningEmulator
        do {
            guard let found = try await directory.runningEmulator(serial: serial) else {
                return AndroidDeviceFacts(id: id, serial: serial, state: .notFound(AndroidError.serialNotRunning(serial).message))
            }
            emulator = found
        } catch {
            return AndroidDeviceFacts(id: id, serial: serial, state: .other(Self.message(error)))
        }
        var facts = AndroidDeviceFacts(id: id, serial: serial, avdName: emulator.avdName, state: Self.state(emulator))
        guard facts.state == .booted else { return facts }
        facts.apiLevel = emulator.apiLevel
        facts.release = emulator.osRelease

        _ = await readDeviceScript(Self.deviceScript, into: &facts, serial: serial, client: client)
        facts.grpc = await grpcFact(emulator)
        return await finishDeviceFacts(facts, serial: serial, client: client)
    }

    /// A USB phone: state from its device-list row, no gRPC; the shell, reverse and helper checks run as on an emulator.
    func phoneFacts(_ id: String, serial: String, directory: AndroidDeviceDirectory, client: AdbClient) async -> AndroidDeviceFacts {
        let phone: ConnectedPhone
        do {
            guard let found = try await directory.connectedPhone(serial: serial) else {
                return AndroidDeviceFacts(id: id, serial: serial, state: .notFound(AndroidError.phoneNotConnected(serial).message))
            }
            phone = found
        } catch {
            return AndroidDeviceFacts(id: id, serial: serial, state: .other(Self.message(error)))
        }
        var facts = AndroidDeviceFacts(id: id, serial: serial, state: Self.state(phone.state, bootCompleted: true))
        facts.isPhysical = true
        facts.model = phone.model
        guard facts.state == .booted else { return facts }
        let lines = await readDeviceScript(Self.phoneScript, into: &facts, serial: serial, client: client, skipping: 2)
        facts.apiLevel = lines.first.flatMap { Int($0) }
        facts.release = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        return await finishDeviceFacts(facts, serial: serial, client: client)
    }

    /// Runs the getprop and settings script; returns its trimmed lines, empty when the shell failed.
    private func readDeviceScript(_ script: String, into facts: inout AndroidDeviceFacts, serial: String, client: AdbClient, skipping offset: Int = 0) async -> [String] {
        guard let result = try? await client.shell(script, on: serial, timeout: .seconds(5), label: "getprop; settings get; pidof") else { return [] }
        let lines = result.stdoutText.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let line = { (index: Int) in index + offset < lines.count ? lines[index + offset] : "" }
        facts.abi = line(0).isEmpty ? nil : line(0)
        facts.uiAutomation = UiAutomationFact(
            accessibilityEnabled: Int(line(1)).map { $0 != 0 },
            enabledServices: line(2) == "null" ? [] : line(2).split(separator: ":").map(String.init).filter { !$0.isEmpty },
            offsiderHelperPids: line(3).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        )
        return lines
    }

    private func finishDeviceFacts(_ facts: AndroidDeviceFacts, serial: String, client: AdbClient) async -> AndroidDeviceFacts {
        var facts = facts
        if let listing = try? await client.deviceQuery("reverse:list-forward", on: serial) {
            facts.reverses = listing.split(whereSeparator: \.isNewline).map(String.init)
        }
        if facts.uiAutomation?.offsiderHelperPids.isEmpty == true {
            facts.helper = await helperFact(serial, client: client)
        }
        return facts
    }

    static func state(_ emulator: RunningEmulator) -> AndroidDeviceStateFact {
        state(emulator.state, bootCompleted: emulator.bootCompleted)
    }

    static func state(_ state: AdbDeviceState, bootCompleted: Bool) -> AndroidDeviceStateFact {
        switch state {
        case .device: return bootCompleted ? .booted : .booting
        case .offline: return .offline
        case .unauthorized: return .unauthorised
        case .other(let state): return .other(state)
        }
    }

    /// The selector's choice without caching: the credential is used once and the client closed again.
    func grpcFact(_ emulator: RunningEmulator) async -> EmulatorGrpcFact {
        let mode: EmulatorTransportSelector.Mode
        do {
            mode = try EmulatorTransportSelector.mode(host: host)
        } catch {
            return .failed(Self.message(error), forced: false)
        }
        if mode == .adb { return .forcedAdb }
        let forced = mode == .grpc
        guard let discovery = emulator.discovery else { return .noDiscoveryFile(forced: forced) }
        guard discovery.grpcPort != nil else { return .noGrpcPort(forced: forced) }
        var auth: EmulatorAuth?
        do {
            let chosen = try await EmulatorAuth.choose(for: discovery, host: host)
            auth = chosen
            let client = try await host.timing.measure(.grpcConnect) {
                try await host.emulatorConnector.connect(discovery: discovery, auth: chosen)
            }
            let start = ContinuousClock.now
            let status: EmulatorStatusSummary
            do {
                status = try await host.timing.measure(.grpcCall) { try await client.status() }
            } catch {
                await client.close()
                throw error
            }
            let milliseconds = HelperLauncher.milliseconds(since: start)
            await client.close()
            let label: String
            switch chosen {
            case .token: label = "token"
            case .jwt: label = "jwt"
            }
            return .connected(endpoint: client.endpoint, auth: label, statusMilliseconds: milliseconds, booted: status.booted)
        } catch {
            auth?.close()
            return .failed(EmulatorRPCErrors.redacted(Self.message(error), discovery: discovery), forced: forced)
        }
    }

    /// One helper start, `ping` and `quit`, as a `describe-ui` would.
    func helperFact(_ serial: String, client: AdbClient) async -> HelperProbeFact {
        if (try? AndroidTreeMode.mode(host: host)) == .uiautomator {
            return .forcedOff
        }
        let dex: HelperDex
        do {
            dex = try host.helperDex()
        } catch let error as HelperDexError {
            return .unavailable(HelperUnavailableReason(error).description)
        } catch {
            return .unavailable(String(describing: error))
        }
        do {
            let session = try await HelperSession.start(client: client, serial: serial, dex: dex, log: { _, _ in }, timing: host.timing)
            let start = ContinuousClock.now
            do {
                try await session.ping()
            } catch {
                await session.close()
                return .unavailable("it did not answer ping: \(Self.message(error))")
            }
            let ping = HelperLauncher.milliseconds(since: start)
            await session.close()
            return .ready(
                launchMilliseconds: session.launchMilliseconds,
                pushed: session.pushed,
                helloMilliseconds: session.helloMilliseconds,
                pingMilliseconds: ping,
                protocolVersion: session.ready.protocol,
                sdkInt: session.ready.sdkInt
            )
        } catch HelperStartFailure.busy(let detail) {
            return .busy(detail)
        } catch HelperStartFailure.unavailable(let reason) {
            return .unavailable(reason.description)
        } catch {
            return .unavailable(Self.message(error))
        }
    }

    // MARK: Fix

    /// `doctor --fix`: the SDK's `adb start-server` with `ADB_MDNS=0`, only when no server answers.
    public func startAdbServerIfAbsent() async -> DoctorFixResult {
        let action = "Start the adb server with ADB_MDNS=0"
        func result(_ outcome: DoctorFixResult.Outcome, _ detail: String) -> DoctorFixResult {
            DoctorFixResult(id: .androidAdbServer, action: action, outcome: outcome, detail: detail)
        }
        let sdk: AndroidSDK
        let client: AdbClient
        do {
            sdk = try AndroidSDK.locate(host: host)
            client = AdbClient(endpoint: try LoopbackEndpoint.adbServer(environment: host.environment), connector: host.adbConnector, timing: host.timing)
        } catch {
            return result(.skipped, "Requires an Android SDK and a loopback adb server setting")
        }
        do {
            _ = try await client.serverVersion()
            return result(.skipped, "The adb server is already running")
        } catch let error as AndroidError where error.kind == .adbServerNotRunning {
        } catch {
            return result(.skipped, Self.message(error))
        }
        do {
            try await AdbServerLauncher(adb: sdk.adb).ensureRunning(client: client, host: host)
            return result(.applied, "Started the adb server on \(client.endpoint)")
        } catch {
            return result(.failed, Self.message(error))
        }
    }

    static func message(_ error: any Error) -> String {
        (error as? AndroidError)?.message ?? String(describing: error)
    }
}
