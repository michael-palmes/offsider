import Foundation
import OffsiderCore

extension AndroidBackend: DisplayControlling {
    /// The active display in its current rotation; the others at their native size.
    public func displays(of id: DeviceID) async throws -> DisplayList {
        let serial = id.rawValue
        let geometry = try await geometry(for: serial)
        let list = try await displayList(serial, refresh: true)
        let active = activeDisplay(in: list, serial: serial)
        let displays = list.displays.map { display in
            guard display.uniqueId == active?.uniqueId else {
                let descriptor = display.descriptor
                return DisplayInfo(descriptor: descriptor, pointWidth: descriptor.pointWidth, pointHeight: descriptor.pointHeight, rotationDegrees: nil, active: false)
            }
            return DisplayInfo(
                descriptor: display.descriptor,
                pointWidth: Self.dp(Double(geometry.logicalWidth) / geometry.scale),
                pointHeight: Self.dp(Double(geometry.logicalHeight) / geometry.scale),
                rotationDegrees: geometry.rotation * 90,
                active: true
            )
        }
        return DisplayList(displays: displays, posture: try await posture(of: id))
    }

    /// The display lines of `dumpsys display`, kept for the command unless `refresh`; throws when it lists no built-in display.
    func displayList(_ serial: String, refresh: Bool = false) async throws -> AndroidDisplayList {
        if !refresh, let cached = displayLists[serial] {
            return cached
        }
        let output = try await settingsShell(AndroidDisplayList.command, on: serial)
        let list = AndroidDisplayList.parse(dumpsys: output)
        guard !list.displays.isEmpty else { throw AndroidError.displaysUnreadable(serial) }
        displayLists[serial] = list
        return list
    }

    /// For `screenInfo`: the active display's role and physical id, and a foldable's posture, in one shell call at most.
    func screenStatus(_ serial: String) async -> (display: ScreenDisplay?, posture: Posture?) {
        if let cached = screenStatuses[serial] {
            return cached
        }
        let status = await readScreenStatus(serial)
        screenStatuses[serial] = status
        return status
    }

    private func readScreenStatus(_ serial: String) async -> (display: ScreenDisplay?, posture: Posture?) {
        var reading: AndroidDeviceState.Reading?
        let known = knownDeviceStates[serial]
        if known == nil || known!.count >= 2 || (activeUniqueIds[serial] == nil && displayLists[serial] == nil) {
            do {
                try await prepare()
                let result = try await requireClient().shell(AndroidDisplayStatus.script, on: serial, label: "cmd device_state; dumpsys display")
                let status = AndroidDisplayStatus.parse(result.stdoutText)
                knownDeviceStates[serial] = status.states
                reading = status.reading
                if !status.displays.displays.isEmpty {
                    displayLists[serial] = status.displays
                }
            } catch {
                log(.debug, "Could not read the displays and posture of \(serial): \(error)")
            }
        }
        let foldable = (knownDeviceStates[serial]?.count ?? 0) >= 2
        if !foldable, let uniqueId = activeUniqueIds[serial], uniqueId.hasPrefix("local:") {
            return (ScreenDisplay(id: DisplayRole.main.rawValue, platformId: String(uniqueId.dropFirst("local:".count))), nil)
        }
        let display = displayLists[serial].flatMap { activeDisplay(in: $0, serial: serial) }?.descriptor.screenDisplay
        return (display, foldable ? reading?.committed.posture : nil)
    }

    func activeDisplay(in list: AndroidDisplayList, serial: String) -> AndroidDisplayList.Physical? {
        list.active ?? list.displays.first { $0.uniqueId == activeUniqueIds[serial] }
    }
}

/// `print-states`, `state` and the display lines of `dumpsys display` in one shell call.
enum AndroidDisplayStatus {
    static let separator = "--- offsider ---"
    static let script = "\(AndroidDeviceState.printStates); echo '\(separator)'; \(AndroidDeviceState.readState); echo '\(separator)'; \(AndroidDisplayList.command)"

    static func parse(_ output: String) -> (states: [AndroidDeviceState.State], reading: AndroidDeviceState.Reading?, displays: AndroidDisplayList) {
        let parts = output.components(separatedBy: separator + "\n")
        let part = { (index: Int) in index < parts.count ? parts[index] : "" }
        return (AndroidDeviceState.parseStates(part(0)), AndroidDeviceState.parseReading(part(1)), AndroidDisplayList.parse(dumpsys: part(2)))
    }
}

extension AndroidBackend: PostureControlling {
    /// `cmd device_state state`; nil when `print-states` lists fewer than two states.
    public func posture(of id: DeviceID) async throws -> Posture? {
        let serial = id.rawValue
        guard try await deviceStates(serial).count >= 2 else { return nil }
        return try await deviceStateReading(serial).committed.posture
    }

    /// gRPC `setPosture` moves the hinge as the extended controls do; without gRPC, a `cmd device_state` override.
    public func requestPosture(_ posture: Posture, on id: DeviceID) async throws {
        let serial = id.rawValue
        let states = try await deviceStates(serial)
        guard states.count >= 2 else { throw AndroidError.notFoldable(serial) }
        let reading = try await deviceStateReading(serial)
        defer { forgetDisplay(of: serial) }
        let match = states.first { $0.posture == posture }
        switch try await transport(for: serial) {
        case .grpc(let emulator):
            if reading.override != nil {
                _ = try await settingsShell(AndroidDeviceState.resetState, on: serial)
            }
            do {
                try await emulator.setPosture(Self.emulatorPosture(posture))
                log(.debug, "Asked \(serial) for \(posture.rawValue) over gRPC setPosture")
            } catch let error as AndroidError {
                guard let match else { throw AndroidError.postureFailed(serial, path: "gRPC setPosture", detail: error.message) }
                log(.debug, "gRPC setPosture failed on \(serial) (\(error.message)); overriding the device state over adb")
                try await overrideState(match, reading: reading, on: serial)
            }
        case .adb(let reason):
            guard let match else {
                throw AndroidError.postureUnavailable(serial, posture: posture, states: states.map(\.name), reason: reason)
            }
            try await overrideState(match, reading: reading, on: serial)
        }
    }

    /// `state reset` when the target is the hinge's own state, else an override; it lasts until reset or reboot.
    private func overrideState(_ state: AndroidDeviceState.State, reading: AndroidDeviceState.Reading, on serial: String) async throws {
        let command = reading.override != nil && reading.base?.identifier == state.identifier
            ? AndroidDeviceState.resetState
            : AndroidDeviceState.setState(state)
        let result = try await requireClient().shell(command, on: serial, label: command)
        guard result.status == 0 else {
            let detail = (result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(result.status)"
            throw AndroidError.postureFailed(serial, path: "adb `\(command)`", detail: detail)
        }
        log(.debug, "Asked \(serial) for \(state.name) with `\(command)`")
    }

    static func emulatorPosture(_ posture: Posture) -> EmulatorPosture {
        switch posture {
        case .closed: return .closed
        case .halfOpened: return .halfOpened
        case .open: return .opened
        case .unknown: return .unknown
        }
    }

    /// `print-states`, once a command; a shell without `device_state` (before API 31) lists none.
    func deviceStates(_ serial: String) async throws -> [AndroidDeviceState.State] {
        if let cached = knownDeviceStates[serial] {
            return cached
        }
        try await prepare()
        let result = try await requireClient().shell(AndroidDeviceState.printStates, on: serial, label: AndroidDeviceState.printStates)
        let states = result.status == 0 ? AndroidDeviceState.parseStates(result.stdoutText) : []
        if result.status != 0 {
            log(.debug, "`\(AndroidDeviceState.printStates)` failed on \(serial), so it is treated as one display: \(result.stderrText)")
        }
        knownDeviceStates[serial] = states
        return states
    }

    /// Never throws: a device whose states cannot be read is treated as not foldable.
    func isFoldable(_ serial: String) async -> Bool {
        do {
            return try await deviceStates(serial).count >= 2
        } catch {
            log(.debug, "Could not read the device states of \(serial): \(error)")
            return false
        }
    }

    func deviceStateReading(_ serial: String) async throws -> AndroidDeviceState.Reading {
        let output = try await settingsShell(AndroidDeviceState.readState, on: serial)
        guard let reading = AndroidDeviceState.parseReading(output) else {
            let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
            throw AndroidError.adbCommandFailed(serial: serial, command: AndroidDeviceState.readState, detail: "expected a committed state but got \(firstLine)")
        }
        return reading
    }

    /// For `screenInfo`: nil on a device with one display, or when the state cannot be read.
    func postureIfFoldable(_ serial: String) async -> Posture? {
        guard await isFoldable(serial) else { return nil }
        do {
            return try await deviceStateReading(serial).committed.posture
        } catch {
            log(.debug, "Could not read the posture of \(serial): \(error)")
            return nil
        }
    }

    /// A posture change recreates the activity on another panel, so the size, rotation and display are read again.
    func forgetDisplay(of serial: String) {
        geometries[serial] = nil
        activeUniqueIds[serial] = nil
        displayLists[serial] = nil
        screenStatuses[serial] = nil
    }
}

extension AndroidBackend: DisplayCapturing {
    /// nil is the active display, over gRPC when it can; a named one is adb's `screencap -d`.
    public func screenshotPNG(for id: DeviceID, display: String?) async throws -> Data {
        guard let display else { return try await screenshotPNG(for: id) }
        let serial = id.rawValue
        let list = try await displayList(serial, refresh: true)
        guard let physical = list.displays.first(where: { $0.descriptor.platformId == display }) else {
            throw AndroidError.unknownDisplay(serial, requested: display, available: list.displays.map(\.descriptor))
        }
        guard physical.on else {
            throw AndroidError.displayOff(serial, display: physical.descriptor, posture: await postureIfFoldable(serial))
        }
        return try await adbScreenshot(serial, physicalDisplay: physical.descriptor.platformId)
    }
}
