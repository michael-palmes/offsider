import Foundation
import OffsiderCore

extension AndroidBackend: AppManaging {
    public func installApp(_ file: ApkFile, as app: String, on id: DeviceID) async throws -> AppInstall {
        let package = try ExpoDevClient.validate(appID: app)
        let installed = AndroidAppPackage.state(in: try await lifecycleShell(AndroidAppPackage.installedScript(package: package), package: package, on: id, label: "pm path"))
        let started = ContinuousClock.now
        let output = try await requireClient().install(file, service: AndroidAppPackage.installService(package: package, size: file.size), on: id.rawValue)
        switch AndroidAppPackage.installReply(output) {
        case .success:
            let elapsed = ContinuousClock.now - started
            let replaced: Bool = if case .installed = installed { true } else { false }
            return AppInstall(app: package, replaced: replaced, bytes: file.size, milliseconds: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
        case .failure(let code):
            throw AndroidAppPackage.installFailure(code: code, package: package, device: id.rawValue)
        case .unknown:
            throw AppLifecycleError(.installFailed, "Android gave no answer to the install of \(package) on \(id.rawValue). Run `offsider app info --app \(package) --device \(id.rawValue)` to see what is there.")
        }
    }

    public func uninstallApp(_ app: String, on id: DeviceID) async throws -> AppUninstall {
        let package = try ExpoDevClient.validate(appID: app)
        let output = try await lifecycleShell(AndroidAppPackage.uninstallScript(package: package), package: package, on: id, label: "pm uninstall")
        if AndroidAppPackage.state(in: output) == .notInstalled { return AppUninstall(app: package, wasInstalled: false) }
        switch AndroidAppPackage.installReply(output) {
        case .success:
            return AppUninstall(app: package, wasInstalled: true)
        case .failure(let code):
            throw AppLifecycleError(.failed, "Android refused to remove \(package) from \(id.rawValue) (\(code)). A system app cannot be removed.")
        case .unknown:
            throw AndroidError.adbCommandFailed(serial: id.rawValue, command: "pm uninstall \(package)", detail: "it did not say whether the app was removed")
        }
    }

    /// Reads only what the device-side filter prints: stderr and stray lines never reach a message.
    public func appPreferences(_ app: String, on id: DeviceID) async throws -> AppPreferences {
        let package = try ExpoDevClient.validate(appID: app)
        try await prepare()
        let result = try await requireClient().shell(AndroidAppPackage.prefsScript(package: package), on: id.rawValue, timeout: .seconds(30), label: "run-as \(package)")
        if let preferences = AndroidAppPackage.preferences(result.stdoutText, package: package) { return preferences }
        let refusal = AndroidAppPackage.runAsLine(result.stderrText) ?? AndroidAppPackage.runAsLine(result.stdoutText)
        if refusal?.contains("not debuggable") == true {
            throw AppLifecycleError(
                .notDebuggable,
                "\(package) is a release build, so Android keeps its preferences from the shell. Nothing was read. Install a debuggable build: `offsider app install <debug.apk> --app \(package) --device \(id.rawValue)`."
            )
        }
        if refusal?.contains("unknown package") == true {
            throw AndroidError.appNotInstalled(package, serial: id.rawValue, adb: adbPath)
        }
        throw AppLifecycleError(.failed, "\(id.rawValue) could not read \(package)'s preferences\(refusal.map { ": \($0)" } ?? " (run-as exit \(result.status))"). Nothing was read.")
    }

    public func sendBroadcast(_ action: String, receiver: String?, to app: String, on id: DeviceID) async throws -> AppBroadcast {
        let package = try ExpoDevClient.validate(appID: app)
        let action = try AppBroadcastName.validate(action: action)
        let receiver = try receiver.map(AppBroadcastName.validate(receiver:))
        let query = try await lifecycleShell(AndroidAppPackage.receiversScript(action: action, receiver: receiver, package: package), package: package, on: id, label: "query-receivers")
        _ = try requireInstalled(query, package: package, on: id)
        let declared = AndroidAppPackage.receivers(query)
        if let receiver, declared.isEmpty {
            throw AppLifecycleError(.receiverNotFound, "\(package) has no receiver \(receiver), so nothing was sent. Check the class name in its manifest.")
        }
        guard declared.isEmpty || declared.contains(where: \.exported) else {
            throw AppLifecycleError(
                .broadcastRefused,
                "\(declared.map(\.name).joined(separator: ", ")) in \(package) is not exported, so Android would drop this silently. Nothing was sent. Set android:exported=\"true\" in a debug manifest."
            )
        }
        let output = try await lifecycleShell(AndroidAppPackage.broadcastScript(action: action, receiver: receiver, package: package), package: package, on: id, label: "am broadcast")
        switch AndroidAppPackage.broadcastReply(output) {
        case .completed(let code):
            return AppBroadcast(app: package, action: action, receiver: receiver, receivers: declared.filter(\.exported).map(\.name), resultCode: code)
        case .denied:
            let own = await ownActions(of: package, on: id)
            let shown = own.prefix(8).joined(separator: ", ") + (own.count > 8 ? " and \(own.count - 8) more" : "")
            let suggestion = own.isEmpty ? "Send an action the app itself declares." : "Its own actions: \(shown)."
            throw AppLifecycleError(.broadcastRefused, "Android keeps \(action) for the system, so the shell cannot send it. Nothing was sent. \(suggestion)")
        case .unknown:
            throw AndroidError.adbCommandFailed(serial: id.rawValue, command: "am broadcast", detail: "it did not say whether the broadcast was sent")
        }
    }

    private func ownActions(of package: String, on id: DeviceID) async -> [String] {
        guard let result = try? await requireClient().shell(ExpoDevClient.androidPackageDumpCommand(package: package), on: id.rawValue, timeout: .seconds(20), label: "dumpsys package") else { return [] }
        return AndroidAppPackage.declaredActions(result.stdoutText, package: package)
    }
}

extension AndroidBackend: AirplaneControlling {
    static let airplanePolls = 10
    static let airplanePollInterval: Duration = .milliseconds(200)

    public func airplaneMode(on id: DeviceID) async throws -> Bool {
        let output = try await settingsShell(AndroidAirplaneRecord.readScript, on: id.rawValue)
        guard let on = AndroidAirplaneRecord.parseSetting(output) else {
            throw AppLifecycleError(.failed, "\(id.rawValue) did not say whether airplane mode is on.")
        }
        return on
    }

    /// The record comes first, so airplane mode is never turned on without one; it goes again if Android refuses.
    public func setAirplaneMode(_ enabled: Bool, on id: DeviceID) async throws -> AirplaneChange {
        let serial = id.rawValue
        let previous = try await airplaneMode(on: id)
        let store = host.airplaneRecordDirectory(enabled).map(AndroidAirplaneRecordStore.init(directory:))
        let earlier = store?.load(serial: serial)
        guard previous != enabled else {
            if !enabled { store?.remove(serial: serial) }
            return AirplaneChange(previous: previous, current: enabled, resetBySessionStop: enabled && earlier != nil)
        }
        if enabled {
            guard let store else {
                throw AppLifecycleError(.failed, "Offsider has no private folder to record airplane mode in, so it left it off.")
            }
            let phone = DeviceID(rawValue: serial, platform: .android).isPhysicalAndroidDevice
            let avd = phone ? nil : await avdName(for: serial)
            guard phone || avd != nil else {
                throw AppLifecycleError(.failed, "Offsider could not read \(serial)'s AVD name, which it needs to undo this later, so it left airplane mode off.")
            }
            try store.save(AndroidAirplaneRecord(serial: serial, avd: avd))
        }
        do {
            try await requireClient().changeAirplaneMode(enabled, on: serial, timing: host, polls: Self.airplanePolls, interval: Self.airplanePollInterval)
        } catch {
            if enabled { store?.remove(serial: serial) }
            throw error
        }
        if !enabled { store?.remove(serial: serial) }
        return AirplaneChange(previous: previous, current: enabled, resetBySessionStop: enabled)
    }

    /// Turns off each recorded airplane mode still on, never starting adb. `device` is a serial or AVD name; nil means all. An unplugged phone or a stopped AVD keeps its record, and another AVD on the same serial is left alone.
    public static func resetRecordedAirplaneModes(host: AndroidHost, serial device: String? = nil, permits: (String) -> Bool = { _ in true }) async -> [String] {
        guard let directory = host.airplaneRecordDirectory(false) else { return [] }
        let store = AndroidAirplaneRecordStore(directory: directory)
        let records = store.all().filter { record in permits(record.serial) && (device == nil || record.serial == device || record.avd == device) }
        guard !records.isEmpty, let endpoint = try? LoopbackEndpoint.adbServer(environment: host.environment) else { return [] }
        let client = AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing)
        guard let rows = try? await client.devices() else { return [] }
        var reset: [String] = []
        for record in records {
            guard let serial = currentSerial(of: record, host: host), rows.contains(where: { $0.serial == serial && $0.state == .device }),
                  let output = try? await client.shell(AndroidAirplaneRecord.readScript, on: serial, label: AndroidAirplaneRecord.readScript),
                  let on = AndroidAirplaneRecord.parseSetting(output.stdoutText) else { continue }
            if on {
                guard (try? await client.changeAirplaneMode(false, on: serial, timing: host, polls: airplanePolls, interval: airplanePollInterval)) != nil else { continue }
                reset.append(serial)
            }
            store.remove(serial: record.serial)
        }
        return reset
    }

    /// A phone keeps its serial; an AVD takes whichever port is free, so it is found by name and never assumed from the serial.
    private static func currentSerial(of record: AndroidAirplaneRecord, host: AndroidHost) -> String? {
        guard let avd = record.avd else { return record.serial }
        return EmulatorDiscovery.live(host: host).first { $0.avdID == avd }.flatMap(\.consolePort).map { "emulator-\($0)" }
    }
}

extension AdbClient {
    /// Streams the file over `exec:`, which needs no temporary copy on the device, and returns Android's reply. A stall of `stallLimit` on any chunk fails; Android then has up to `replyLimit` to verify the app.
    func install(_ file: ApkFile, service: String, on serial: String, stallLimit: Duration = .seconds(60), replyLimit: Duration = .seconds(300)) async throws -> String {
        let chunk = 1 << 20
        let opened = try await openService(service, on: serial, timeout: .seconds(15))
        var output = opened.pending
        var lost = false
        do {
            var offset = 0
            while offset < file.size {
                let count = min(chunk, file.size - offset)
                guard let bytes = file.read(at: offset, count: count) else {
                    await opened.stream.close()
                    throw AppLifecycleError(.apkUnreadable, "\(file.path) could not be read to the end, so nothing was installed.")
                }
                try await opened.stream.write(bytes, deadline: ContinuousClock.now + stallLimit)
                offset += count
            }
        } catch is AdbConnectError {
            // Android may have refused early and closed its end, so its reply is still worth reading.
            lost = true
        }
        let deadline = ContinuousClock.now + (lost ? .seconds(2) : replyLimit)
        do {
            while output.count < 64 * 1024 {
                let more = try await opened.stream.read(upTo: 4096, deadline: deadline)
                if more.isEmpty { break }
                output.append(more)
            }
        } catch is AdbConnectError {
            lost = true
        }
        await opened.stream.close()
        let text = String(decoding: output, as: UTF8.self)
        if lost || text.isEmpty, AndroidAppPackage.installReply(text) == .unknown {
            throw AppLifecycleError(.installFailed, "The connection to \(serial) dropped during the install, so nothing was installed. Check the cable, then run the same command again.")
        }
        return text
    }

    /// Asks Android, then waits until the setting reads back, as the change lands a moment after the command returns.
    func changeAirplaneMode(_ enabled: Bool, on serial: String, timing host: AndroidHost, polls: Int, interval: Duration) async throws {
        let script = AndroidAirplaneRecord.script(enabled: enabled)
        let result = try await shell(script, on: serial, label: script)
        guard result.status == 0 else {
            throw AppLifecycleError(.failed, "\(serial) refused to change airplane mode, which needs Android 11 or later. Can you set it in Quick Settings on \(serial)?")
        }
        for _ in 0..<polls {
            let output = try await shell(AndroidAirplaneRecord.readScript, on: serial, label: AndroidAirplaneRecord.readScript)
            if AndroidAirplaneRecord.parseSetting(output.stdoutText) == enabled { return }
            try await host.sleep(interval)
        }
        throw AppLifecycleError(.failed, "\(serial) did not turn airplane mode \(enabled ? "on" : "off"). Can you set it in Quick Settings on \(serial)?")
    }
}
