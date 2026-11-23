import Foundation
import OffsiderCore

extension AndroidBackend: ScreenReaderControlling {
    public var screenReaderService: String { AndroidScreenReader.service }
    /// The TalkBack services Offsider knows, as Android lists them when enabled.
    public nonisolated static var screenReaderComponents: [String] { AndroidScreenReader.components }

    private func screenReaderStore(create: Bool) -> AndroidScreenReaderRecordStore? {
        host.screenReaderRecordDirectory(create).map(AndroidScreenReaderRecordStore.init(directory:))
    }

    /// The record for the device now on `serial`: an emulator's port passes from one AVD to the next, so another AVD's record is not this one's.
    private func screenReaderRecord(_ serial: String, in store: AndroidScreenReaderRecordStore?) -> AndroidScreenReaderRecord? {
        store?.load(serial: serial).flatMap { $0.avd == host.avdName(of: serial) ? $0 : nil }
    }

    public func screenReaderIsRecorded(on id: DeviceID) -> Bool {
        screenReaderRecord(id.rawValue, in: screenReaderStore(create: false))?.turnedOn == true
    }

    public func screenReader(on id: DeviceID) async throws -> Bool {
        let state = try await screenReaderState(id.rawValue)
        return AndroidScreenReader.components.contains { state.isOn($0) }
    }

    /// Whether TalkBack is noted as on for `serial`, turned on by Offsider or found on by `screen-reader on`: a file on this Mac, so it costs no adb call.
    func screenReaderIsNoted(_ serial: String) -> Bool {
        screenReaderRecord(serial, in: screenReaderStore(create: false)) != nil
    }

    /// Whether TalkBack is noted as on for `serial` without reaching it: nil for no note, true when Offsider turned it on, false when a person had.
    public static func screenReaderNote(host: AndroidHost, serial: String) -> Bool? {
        guard let directory = host.screenReaderRecordDirectory(false) else { return nil }
        return AndroidScreenReaderRecordStore(directory: directory).load(serial: serial).flatMap { $0.avd == host.avdName(of: serial) ? $0.turnedOn : nil }
    }

    /// Android's own flag, polled while TalkBack starts; false if it never came on.
    private func waitForTouchExploration(_ serial: String) async throws -> Bool {
        for _ in 0..<AndroidScreenReader.polls {
            if AndroidScreenReader.parseFlag(try await settingsShell(AndroidScreenReader.touchScript, on: serial)) == true { return true }
            try await host.sleep(AndroidScreenReader.pollInterval)
        }
        return false
    }

    private func screenReaderState(_ serial: String) async throws -> AndroidScreenReader.State {
        guard let state = AndroidScreenReader.parseState(try await settingsShell(AndroidScreenReader.stateScript, on: serial)) else {
            throw ScreenReaderError("\(serial) did not say whether TalkBack is on.")
        }
        return state
    }

    /// The record comes first, so TalkBack is never turned on without one; a change that fails is undone, and the record goes once TalkBack reads off.
    public func setScreenReader(_ enabled: Bool, on id: DeviceID) async throws -> ScreenReaderChange {
        let serial = id.rawValue
        let state = try await screenReaderState(serial)
        let store = screenReaderStore(create: enabled)
        let earlier = screenReaderRecord(serial, in: store)
        let listed = AndroidScreenReader.components.first(where: state.services.contains)
        let wasOn = state.isOn(listed)
        let client = try requireClient()
        guard enabled else {
            guard listed != nil || earlier != nil else { return ScreenReaderChange(previous: false, current: false, resetBySessionStop: false) }
            guard try await client.turnOffScreenReader(on: serial, record: earlier, timing: host) else {
                throw ScreenReaderError("\(serial) did not turn TalkBack off in time. Run the command again.")
            }
            if earlier != nil { store?.remove(serial: serial) }
            return ScreenReaderChange(previous: wasOn, current: false, resetBySessionStop: false)
        }
        let phone = id.isPhysicalAndroidDevice
        let avd = phone ? nil : await avdName(for: serial)
        // Enabled by someone else, and perhaps still starting: it is theirs, so it is noted and never recorded as Offsider's.
        if let listed {
            let started = wasOn ? true : try await waitForTouchExploration(serial)
            guard started else {
                throw ScreenReaderError("TalkBack is enabled on \(serial) but has not started. Turn it off with `offsider screen-reader off --device \(serial)`, then on again.", hint: "offsider screen-reader off --device \(serial)")
            }
            if earlier == nil { try? store?.save(AndroidScreenReaderRecord(serial: serial, avd: avd, component: listed, turnedOn: false)) }
            return ScreenReaderChange(previous: wasOn, current: true, resetBySessionStop: earlier?.turnedOn == true)
        }
        guard phone || avd != nil else {
            throw ScreenReaderError("Offsider could not read \(serial)'s AVD name, which it needs to undo this later, so it left TalkBack off.")
        }
        if let avd, !emulatorIsSilent(serial) {
            throw ScreenReaderError(
                "\(serial) was not started with -no-audio, so TalkBack would speak on this Mac, and Offsider left it off. Stop the emulator, then start it with `offsider boot \(avd)`.",
                reason: .notSupported, hint: "offsider shutdown \(avd)"
            )
        }
        guard let component = AndroidScreenReader.installed(try await settingsShell(AndroidScreenReader.installedScript, on: serial)) else {
            throw ScreenReaderError(
                "TalkBack is not installed on \(serial), so there is no screen reader to turn on. An emulator image with Google APIs or Google Play ships it.",
                reason: .notSupported
            )
        }
        guard let store else {
            throw ScreenReaderError("Offsider has no private folder to record the screen reader in, so it left it off.")
        }
        let grantedScript = AndroidScreenReader.grantedScript(component: component)
        let granted = AndroidScreenReader.parseGranted((try? await client.shell(grantedScript, on: serial, label: "dumpsys package"))?.stdoutText ?? "")
        let ours = earlier.flatMap { $0.turnedOn ? $0 : nil }
        let record = AndroidScreenReaderRecord(serial: serial, avd: avd, component: component, turnedOn: true, grantedNotifications: ours?.grantedNotifications == true || granted == false)
        try store.save(record)
        do {
            // Without it TalkBack asks to send notifications each time it starts, over the app under test.
            if granted == false {
                let grant = AndroidScreenReader.permissionScript(grant: true, component: component)
                guard try await client.shell(grant, on: serial, label: grant).status == 0 else {
                    throw ScreenReaderError("\(serial) would not let Offsider answer TalkBack's notification prompt ahead of time, so it left TalkBack off.")
                }
            }
            let write = AndroidScreenReader.writeScript(services: state.services + [component])
            guard try await client.shell(write, on: serial, label: "settings put secure enabled_accessibility_services").status == 0 else {
                throw ScreenReaderError("\(serial) refused to enable TalkBack.")
            }
            guard try await waitForTouchExploration(serial) else { throw ScreenReaderError("\(serial) did not turn TalkBack on in time.") }
            if store.load(serial: serial) == nil { try store.save(record) }
        } catch {
            if (try? await client.turnOffScreenReader(on: serial, record: record, timing: host)) == true { store.remove(serial: serial) }
            throw error
        }
        return ScreenReaderChange(previous: false, current: true, resetBySessionStop: true)
    }

    /// An emulator with no discovery file cannot be shown to be silent, so it counts as one that is not.
    private func emulatorIsSilent(_ serial: String) -> Bool {
        guard case .androidSerial(let port) = DeviceIDClassifier.classify(serial) else { return false }
        return EmulatorDiscovery.live(host: host).first { $0.consolePort == port }?.isSilent ?? false
    }

    /// Turns off each TalkBack Offsider turned on, never starting adb. `device` is a serial or AVD name; nil means all. An unplugged phone or a stopped AVD keeps its record, and one a person turned on only loses its record.
    public static func resetRecordedScreenReaders(host: AndroidHost, serial device: String? = nil, permits: (String) -> Bool = { _ in true }) async -> RecordResetOutcome {
        guard let directory = host.screenReaderRecordDirectory(false) else { return RecordResetOutcome() }
        let store = AndroidScreenReaderRecordStore(directory: directory)
        let named = store.all().filter { device == nil || isRecord(serial: $0.serial, avd: $0.avd, of: device!, host: host) }
        for record in named where !record.turnedOn { store.remove(serial: record.serial) }
        let all = named.filter(\.turnedOn)
        let records = all.filter { permits($0.serial) }
        let unpermitted = all.map(\.serial).filter { phone in !records.contains { $0.serial == phone } }
        var outcome = RecordResetOutcome()
        guard !all.isEmpty else { return outcome }
        let endpoint = try? LoopbackEndpoint.adbServer(environment: host.environment)
        let client = endpoint.map { AdbClient(endpoint: $0, connector: host.adbConnector, timing: host.timing) }
        guard let client, let rows = try? await client.devices() else {
            outcome.notConnected = records.map(\.name)
            outcome.skipped = unpermitted
            return outcome
        }
        outcome.skipped = store.keptNaming(unpermitted, connected: rows.map(\.serial))
        for record in records {
            guard let serial = currentSerial(serial: record.serial, avd: record.avd, host: host), rows.contains(where: { $0.serial == serial && $0.state == .device }) else {
                if !store.keptNaming([record.serial], connected: []).isEmpty { outcome.notConnected.append(record.name) }
                continue
            }
            guard let output = try? await client.shell(AndroidScreenReader.stateScript, on: serial, label: AndroidScreenReader.stateScript),
                  let state = AndroidScreenReader.parseState(output.stdoutText),
                  (try? await client.turnOffScreenReader(on: serial, record: record, timing: host)) == true else {
                outcome.failed.append(serial)
                continue
            }
            if AndroidScreenReader.components.contains(where: state.services.contains) { outcome.reset.append(serial) }
            store.remove(serial: record.serial)
        }
        return outcome
    }
}

extension AdbClient {
    /// TalkBack out of the enabled list, then what Offsider changed for it put back; true once the list reads without it.
    func turnOffScreenReader(
        on serial: String, record: AndroidScreenReaderRecord?, timing host: AndroidHost,
        polls: Int = AndroidScreenReader.polls, interval: Duration = AndroidScreenReader.pollInterval
    ) async throws -> Bool {
        func state() async throws -> AndroidScreenReader.State {
            let output = try await shell(AndroidScreenReader.stateScript, on: serial, label: AndroidScreenReader.stateScript)
            guard let state = AndroidScreenReader.parseState(output.stdoutText) else { throw ScreenReaderError("\(serial) did not say whether TalkBack is on.") }
            return state
        }
        let before = try await state()
        let remaining = before.services.filter { !AndroidScreenReader.components.contains($0) }
        if remaining != before.services {
            let write = AndroidScreenReader.writeScript(services: remaining)
            guard try await shell(write, on: serial, label: "settings put secure enabled_accessibility_services").status == 0 else { return false }
        }
        var off = false
        for _ in 0..<polls {
            let now = try await state()
            // Another service may keep touch exploration on, which is not Offsider's to change.
            if !AndroidScreenReader.components.contains(where: now.services.contains), !now.touchExploration || !remaining.isEmpty {
                off = true
                break
            }
            try await host.sleep(interval)
        }
        guard off else { return false }
        if let record, record.turnedOn, record.grantedNotifications {
            let revoke = AndroidScreenReader.permissionScript(grant: false, component: record.component)
            _ = try? await shell(revoke, on: serial, label: revoke)
        }
        return true
    }
}
