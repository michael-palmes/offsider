import Foundation
import OffsiderCore

extension AndroidBackend {
    /// How this command reads `serial`'s screen, chosen once: the helper, else uiautomator, announced on the first screen read.
    func treeSource(for serial: String, announcingFallback: Bool = true) async throws -> AndroidTreeSource {
        if let chosen = treeSources[serial] {
            if announcingFallback { announceFallback(chosen, on: serial) }
            return chosen
        }
        let mode = try AndroidTreeMode.mode(host: host)
        let chosen: AndroidTreeSource
        if mode == .uiautomator {
            chosen = .uiautomator(.forcedOff)
        } else {
            try await prepare()
            do {
                chosen = .helper(try await startHelper(serial))
            } catch HelperStartFailure.unavailable(let reason) {
                guard mode == .auto else {
                    throw AndroidError.helperUnavailableForced(serial, reason: reason)
                }
                chosen = .uiautomator(reason)
            }
        }
        treeSources[serial] = chosen
        if announcingFallback { announceFallback(chosen, on: serial) }
        return chosen
    }

    private func announceFallback(_ source: AndroidTreeSource, on serial: String) {
        guard case .uiautomator(let reason) = source, reason != .forcedOff, announcedFallbacks.insert(serial).inserted else { return }
        log(.warning, AndroidTreeSource.fallbackWarning(serial: serial, reason: reason))
    }

    /// For `type --replace`: one `setText` on the focused field, else `.useKeys` (with a warning unless uiautomator was forced).
    func replaceFocusedText(_ text: String, on serial: String) async throws -> TextReplacement {
        let session: HelperSession
        switch try await treeSource(for: serial, announcingFallback: false) {
        case .helper(let running):
            session = running
        case .uiautomator(.forcedOff):
            return .useKeys(warning: nil)
        case .uiautomator(let reason):
            return .useKeys(warning: "type --replace could not use the UiAutomation helper on \(serial) (\(reason)), so Offsider clears the field with Ctrl+A and Delete, then types.")
        }
        let refusal: String
        do {
            let result = try await session.setText(text)
            log(.debug, "The helper set the text of \(result.className ?? "the focused field") on \(serial)")
            return .replaced
        } catch let error as HelperErrorBody {
            switch error.code {
            case "no-focus": throw AndroidError.noFocusedField(serial)
            case "not-editable": throw AndroidError.fieldNotEditable(serial, className: error.className, resourceId: error.resourceId)
            default: refusal = error.message
            }
        } catch let error as HelperProtocolError {
            refusal = error.detail
        } catch HelperStartFailure.busy {
            throw await busyError(serial)
        }
        return .useKeys(warning: "The focused field on \(serial) does not accept replacement text (\(refusal)), so Offsider clears it with Ctrl+A and Delete, then types.")
    }

    /// The helper this command already started on `serial`, for callers that must never start one.
    func runningHelper(for serial: String) -> HelperSession? {
        guard case .helper(let session) = treeSources[serial] else { return nil }
        return session
    }

    /// One dump mapped to dp; a dump with no app window is read once more after 500 ms, then `noWindow`.
    func helperRoots(_ serial: String, session: HelperSession) async throws -> [UINode] {
        var dump = try await helperDump(serial, session: session)
        if HelperTreeMapping.appWindow(in: dump) == nil {
            log(.debug, "The helper found no window on \(serial); reading the screen again")
            try await host.sleep(.milliseconds(500))
            dump = try await helperDump(serial, session: session)
            guard HelperTreeMapping.appWindow(in: dump) != nil else {
                throw AndroidError.noWindow(serial)
            }
        }
        let geometry: AndroidDisplayGeometry
        if let measured = AndroidDisplayGeometry(display: dump.display) {
            geometries[serial] = measured
            geometry = measured
        } else {
            geometry = try await self.geometry(for: serial)
        }
        if dump.truncated, warnedAboutTruncation.insert(serial).inserted {
            log(.warning, AndroidTreeSource.truncationWarning(serial: serial))
        }
        let mapped = HelperTreeMapping.roots(from: dump, scale: geometry.scale, pid: session.ready.pid)
        session.remember(mapped.index)
        return mapped.roots
    }

    /// `ACTION_SET_PROGRESS` on `node` from this command's latest dump; a node that moved since is `.stale`.
    public func setRangeValue(_ fraction: Double, of node: UINode, on id: DeviceID) async throws -> RangeActionOutcome {
        let serial = id.rawValue
        let session: HelperSession
        switch try await treeSource(for: serial) {
        case .helper(let running): session = running
        case .uiautomator(let reason): throw AndroidError.sliderNeedsHelper(serial, reason: reason)
        }
        guard let index = session.index, index.pid == session.ready.pid,
              let entry = index.entries.first(where: { $0.node == node }) else {
            log(.debug, "The slider is not in the latest helper dump of \(serial)")
            return .stale
        }
        guard let range = entry.range, range.type != "indeterminate", range.min.isFinite, range.max.isFinite, range.max > range.min else {
            return .unsupported(reason: "\(entry.ref.className ?? "the element") reports no range")
        }
        let target = SliderMath.target(fraction: fraction, range: range)
        do {
            _ = try await session.setProgress(entry.ref, value: target.value, expecting: range)
        } catch let error as HelperErrorBody where error.code == "stale-node" {
            log(.debug, "The helper on \(serial) refused a stale slider: \(error.message)")
            return .stale
        } catch let error as HelperErrorBody {
            return .unsupported(reason: error.message)
        } catch let error as HelperProtocolError {
            return .unsupported(reason: error.detail)
        } catch HelperStartFailure.busy {
            throw await busyError(serial)
        }
        return .performed(reachable: target.reachable)
    }

    /// Wakes on the first relevant event after the latest dump; with no helper running, or when the wait fails, sleeps `timeout`.
    public func waitForAccessibilityChange(on id: DeviceID, timeout: Duration) async throws -> Bool {
        let serial = id.rawValue
        if let session = runningHelper(for: serial) {
            do {
                return try await !session.events(waitingUpTo: timeout).isEmpty
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log(.debug, "Waiting for accessibility events on \(serial) failed (\(error)); waiting \(timeout) instead")
            }
        }
        try await host.sleep(timeout)
        return false
    }

    private func helperDump(_ serial: String, session: HelperSession) async throws -> HelperDump {
        do {
            return try await session.dump()
        } catch HelperStartFailure.busy {
            throw await busyError(serial)
        }
    }

    /// Starts the helper; when the slot is busy with an Offsider helper, waits up to 2 s for it to go and tries once more.
    private func startHelper(_ serial: String) async throws -> HelperSession {
        let dex: HelperDex
        do {
            dex = try host.helperDex()
        } catch let error as HelperDexError {
            log(.debug, "The bundled helper cannot be used: \(error)")
            throw HelperStartFailure.unavailable(HelperUnavailableReason(error))
        }
        let client = try requireClient()
        do {
            return try await HelperSession.start(client: client, serial: serial, dex: dex, log: log)
        } catch HelperStartFailure.busy(let detail) {
            log(.debug, "UiAutomation is busy on \(serial): \(detail)")
        }
        var pids = await helperPids(serial)
        guard !pids.isEmpty else {
            throw AndroidError.helperBusy(serial)
        }
        var polls = 0
        while !pids.isEmpty, polls < 8 {
            try await host.sleep(.milliseconds(250))
            polls += 1
            pids = await helperPids(serial)
        }
        if let stale = pids.first {
            throw AndroidError.helperBusy(serial, stalePid: stale)
        }
        do {
            return try await HelperSession.start(client: client, serial: serial, dex: dex, log: log)
        } catch HelperStartFailure.busy {
            throw await busyError(serial)
        }
    }

    private func busyError(_ serial: String) async -> AndroidError {
        if let pid = await helperPids(serial).first {
            return .helperBusy(serial, stalePid: pid)
        }
        return .helperBusy(serial)
    }

    /// Offsider helpers running on `serial`, by their process name; never killed here, as another command may own them.
    private func helperPids(_ serial: String) async -> [Int32] {
        guard let result = try? await requireClient().shell("pidof \(HelperLauncher.processName)", on: serial, timeout: .seconds(2)) else {
            return []
        }
        return result.stdoutText.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }
}
