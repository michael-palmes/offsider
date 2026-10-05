import Foundation
import OffsiderCore

/// The broker's hold on one wired device: its UniversalHID service for touches and keys, its HID button socket and its screen stream.
@MainActor
public final class CoreDeviceSessionHardware: DeviceSessionHardware {
    /// A live stream that delivers no new frame for this long has died; a still screen keeps sending frames.
    static let stallLimit: Duration = .seconds(6)
    /// The wait before re-opening a failed stream, doubling with each failure in a row up to `reopenCeiling`.
    static let reopenInterval: Duration = .seconds(5)
    static let reopenCeiling: Duration = .seconds(60)
    /// A failed UniversalHID open is tried again on the next input after this long.
    static let hidRetryDelay: Duration = .seconds(2)
    static let presenceInterval: Duration = .seconds(30)
    /// The panel's orientation is read again this often in the background while the broker is in use.
    static let panelInterval: Duration = .seconds(2)
    /// Touches and `ping`'s geometry use a display read that started at most this long ago, so a turn of the screen is seen.
    static let panelMaxAge: Duration = .seconds(1)
    static let activeWindow: Duration = .seconds(60)
    static let touchscreenFallback: UInt64 = 257
    static let keyboardFallback: UInt64 = 512

    let udid: String
    let host: IOSDeviceHost
    let log: IOSDeviceLog
    private let version: CoreDeviceVersion?
    private var stream: IOSDeviceScreenStream?
    private var opening: Task<Void, Never>?
    private var streamClosing: Task<Void, Never>?
    private var failure: IOSDeviceError?
    private var buttons: DeviceDTUHID?
    private var target: (identifier: String, name: String)?
    private var listing: Task<ListedDevice, Error>?
    /// Set once a listing shows the device unlisted, unavailable or off USB; the broker then ends.
    private var gone: IOSDeviceError?
    private var hidTried = false
    private var buttonsTried = false
    private var lastFrames = 0
    private var lastProgress = ContinuousClock.now
    private var failedReopens = 0
    private var lastAttempt = ContinuousClock.now
    private var lastPresence = ContinuousClock.now
    private var closed = false
    private var hid: UniversalHIDService?
    private var hidOpening: Task<UniversalHIDService, Error>?
    private var buttonsOpening: Task<DeviceDTUHID, Error>?
    private var hidFailure: IOSDeviceError?
    private var hidFailedAt = ContinuousClock.now
    private var surfaces: (touchscreen: UInt64, keyboard: UInt64) = (touchscreenFallback, keyboardFallback)
    private var panel: IOSDevicePanel?
    private var geometry: IOSDeviceGeometry?
    private var panelReadAt = ContinuousClock.now
    private var panelRefresh: Task<Void, Never>?
    private var panelRefreshID = 0
    private var panelError: Error?
    /// Bumped when the display changes, so a read that started before it is discarded.
    private var panelGeneration = 0
    private var refreshGeneration = 0
    private var lastUse = ContinuousClock.now
    /// What the input in flight holds down, released if it stops early or the broker closes.
    private var heldContact: (x: UInt16, y: UInt16)?
    private var heldKeys = false
    private var heldButton: (page: UInt64, code: UInt64)?

    public init(udid: String, host: IOSDeviceHost = .live(), version: CoreDeviceVersion? = CoreDeviceVersion.installed(), log: @escaping IOSDeviceLog) {
        self.udid = udid
        self.host = host
        self.version = version
        self.log = log
    }

    /// Optimistic once a failed HID open is due a retry, so the client routes input here and the next request retries it.
    public var supportsTouch: Bool { version?.supportsHID == true && (hidFailure == nil || hidRetryDue) }

    private var hidRetryDue: Bool { ContinuousClock.now - hidFailedAt >= Self.hidRetryDelay }

    /// How long after a failed open the stream is tried again.
    static func reopenDelay(afterFailures failures: Int) -> Duration {
        guard failures > 1 else { return reopenInterval }
        return min(reopenInterval * (1 << min(failures - 1, 6)), reopenCeiling)
    }

    private var reopenDue: Bool { ContinuousClock.now - lastAttempt >= Self.reopenDelay(afterFailures: failedReopens) }

    /// The device's model label once listed.
    public var label: String? { target?.name }

    public var streamStatus: DeviceSessionStreamStatus {
        if let stream {
            return DeviceSessionStreamStatus(state: .live, width: stream.width, height: stream.height, framesReceived: stream.framesReceived)
        }
        if closed { return DeviceSessionStreamStatus(state: .closed) }
        if let failure { return DeviceSessionStreamStatus(state: .failed, detail: failure.message) }
        return DeviceSessionStreamStatus(state: .opening)
    }

    /// Touch input first, since it is quickest to need, then the button socket, then the stream.
    public func start() async {
        let input = Task {
            _ = try? await self.hidService()
            _ = try? await self.buttonLink()
        }
        await beginOpening().value
        await input.value
    }

    /// One open at a time, after any stream still closing; it runs on even when its caller stops waiting.
    @discardableResult
    private func beginOpening() -> Task<Void, Never> {
        if let opening { return opening }
        let closing = streamClosing
        let task = Task {
            await closing?.value
            await self.attemptOpen()
            self.opening = nil
        }
        opening = task
        return task
    }

    private func attemptOpen() async {
        lastAttempt = .now
        do {
            let device = try await currentDevice()
            guard let version, version.supportsHID else { throw IOSDeviceError.xcodeTooOld(device.name, version: version) }
            guard let tunnel = device.tunnel else {
                throw IOSDeviceError.streamFailed(device.name, udid: udid, detail: "devicectl reported no CoreDevice tunnel address")
            }
            let opened = try await IOSDeviceScreenStream.open(
                deviceIdentifier: device.identifier, version: version, name: device.name, udid: udid, tunnelAddress: tunnel, timing: host.timing
            )
            guard !closed else {
                await opened.close()
                return
            }
            stream = opened
            failure = nil
            failedReopens = 0
            lastFrames = 0
            lastProgress = .now
            log(.info, "Stream open: \(opened.width) x \(opened.height)")
        } catch {
            failure = (error as? IOSDeviceError) ?? IOSDeviceError.streamFailed(udid, udid: udid, detail: error.localizedDescription)
            failedReopens += 1
            log(.info, "Stream failed: \(failure?.message ?? "")")
        }
    }

    typealias ListedDevice = (identifier: String, name: String, tunnel: String?)

    /// A fresh listing, which callers asking while one runs share; a device gone or off USB ends the broker.
    private func currentDevice() async throws -> ListedDevice {
        if let listing { return try await listing.value }
        let task = Task { try await self.listAndRecord() }
        listing = task
        defer { listing = nil }
        return try await task.value
    }

    private func listAndRecord() async throws -> ListedDevice {
        do {
            let device = try await listDevice()
            target = (device.identifier, device.name)
            return device
        } catch let error as IOSDeviceError where [.notListed, .unavailable, .notWired].contains(error.kind) {
            gone = error
            throw error
        }
    }

    private func listDevice() async throws -> ListedDevice {
        guard let device = try await IOSDeviceDirectory(host: host).device(udid: udid) else { throw IOSDeviceError.notListed(udid) }
        let name = DeviceName.display(device.udid, label: device.label)
        guard device.connectionState != "unavailable" else { throw IOSDeviceError.unavailable(name) }
        guard device.transportType == "wired" else { throw IOSDeviceError.notWired(name) }
        guard let identifier = device.coreDeviceIdentifier else {
            throw IOSDeviceError.streamFailed(name, udid: udid, detail: "devicectl did not report its CoreDevice identifier")
        }
        return (identifier, name, device.tunnelAddress)
    }

    /// A stream waiting out its back-off fails at once, so the client captures with devicectl instead of waiting.
    public func frame(_ format: IOSDeviceScreenFrame.Format) async throws -> IOSDeviceScreenFrame {
        lastUse = .now
        if stream == nil {
            if let opening {
                await opening.value
            } else if failure == nil || (failure?.kind != .streamNeedsGUISession && reopenDue) {
                await beginOpening().value
            }
        }
        guard let stream else {
            throw failure ?? IOSDeviceError.streamFailed(udid, udid: udid, detail: "the stream did not open")
        }
        do {
            return try await stream.latestFrame(format)
        } catch {
            dropStream(stream, error)
            throw error
        }
    }

    /// The button stays down for `hold` only while its client stays connected, and is always released.
    public func press(usagePage: UInt64, usageCode: UInt64, hold: Double, abandoned: @Sendable () -> Bool) async throws {
        lastUse = .now
        let link = try await buttonLink()
        link.send(DTUHIDMessage.button(usagePage: usagePage, usage: usageCode, state: .down))
        heldButton = (usagePage, usageCode)
        let held = await Self.pause(until: .now + .seconds(hold), abandoned: abandoned)
        link.send(DTUHIDMessage.button(usagePage: usagePage, usage: usageCode, state: .up))
        heldButton = nil
        try await confirm(link)
        if !held { throw Self.clientLeft }
    }

    public func touch(_ steps: [DeviceSessionStep], abandoned: @Sendable () -> Bool) async throws {
        lastUse = .now
        let reports = try DeviceSessionReports.touch(steps, panel: try await currentPanel())
        try await play(reports, abandoned: abandoned)
    }

    public func keys(_ steps: [DeviceSessionStep], abandoned: @Sendable () -> Bool) async throws {
        lastUse = .now
        try await play(try DeviceSessionReports.keys(steps), abandoned: abandoned)
    }

    static let clientLeft = IOSDeviceError(.sessionFailed, "The command that sent this input disconnected while it was held, so the device session released it early.")

    /// Sleeps in short slices until `due`; false, at once, when the client has gone.
    static func pause(until due: ContinuousClock.Instant, abandoned: () -> Bool) async -> Bool {
        while true {
            if abandoned() { return false }
            let now = ContinuousClock.now
            guard due > now else { return true }
            try? await Task.sleep(until: min(due, now + .milliseconds(100)), clock: .continuous)
        }
    }

    /// Sends each report against a clock started at the first, so many short pauses keep the gesture's total time, then confirms delivery.
    /// A client that disconnects mid-request has what it held released at once.
    private func play(_ reports: [DeviceSessionReport], abandoned: @Sendable () -> Bool) async throws {
        let service = try await hidService()
        let start = ContinuousClock.now
        var elapsed = 0.0
        var completed = true
        for report in reports {
            switch report {
            case let .touch(x, y, state):
                service.send(UniversalHIDReport.touchscreen(x: x, y: y, state: state, timestamp: UniversalHIDReport.timestamp()), to: surfaces.touchscreen)
                heldContact = state == .contact ? (x, y) : nil
            case .keyboard(let pressed):
                service.send(UniversalHIDReport.keyboard(pressedUsages: pressed, timestamp: UniversalHIDReport.timestamp()), to: surfaces.keyboard)
                heldKeys = !pressed.isEmpty
            case .sleep(let seconds):
                elapsed += seconds
                completed = await Self.pause(until: start + .seconds(elapsed), abandoned: abandoned)
            }
            if !completed { break }
        }
        releaseHeldInput(service)
        do {
            try await service.confirm()
        } catch {
            hid = nil
            service.close()
            throw error
        }
        if !completed { throw Self.clientLeft }
    }

    /// Lifts a contact and releases keys an interrupted request left down.
    private func releaseHeldInput(_ service: UniversalHIDService) {
        if let contact = heldContact {
            service.send(UniversalHIDReport.touchscreen(x: contact.x, y: contact.y, state: .release, timestamp: UniversalHIDReport.timestamp()), to: surfaces.touchscreen)
            heldContact = nil
        }
        if heldKeys {
            service.send(UniversalHIDReport.keyboard(pressedUsages: [], timestamp: UniversalHIDReport.timestamp()), to: surfaces.keyboard)
            heldKeys = false
        }
    }

    /// The UniversalHID service, kept open; it waits out its own activation window once when it opens.
    /// After a failed open, input fails with that failure until a retry is due.
    private func hidService() async throws -> UniversalHIDService {
        if let hid { return hid }
        if let hidOpening { return try await hidOpening.value }
        if let gone { throw gone }
        if let hidFailure, !hidRetryDue { throw hidFailure }
        let task = Task { try await self.openHID() }
        hidOpening = task
        defer { hidOpening = nil }
        return try await task.value
    }

    private func openHID() async throws -> UniversalHIDService {
        do {
            let reopening = hidTried
            hidTried = true
            let device = try await openTarget(reopening: reopening)
            guard let version, version.supportsHID else { throw IOSDeviceError.xcodeTooOld(device.name, version: version) }
            let service = try await UniversalHIDService.connect(deviceIdentifier: device.identifier, version: version, name: device.name, udid: udid)
            let listed = try await service.connectedServices()
            surfaces = (listed.first(.touchscreen)?.id ?? Self.touchscreenFallback, listed.first(.keyboard)?.id ?? Self.keyboardFallback)
            hid = service
            hidFailure = nil
            log(.info, "UniversalHID open: touchscreen \(surfaces.touchscreen), keyboard \(surfaces.keyboard)")
            return service
        } catch {
            hidFailure = (error as? IOSDeviceError) ?? IOSDeviceError.hidFailed(target?.name ?? udid, udid: udid, detail: error.localizedDescription, sent: false)
            hidFailedAt = .now
            throw error
        }
    }

    /// The panel from a read that started at most `panelMaxAge` before this touch, read now when the cached one is older;
    /// when the read fails, the last panel serves.
    private func currentPanel() async throws -> IOSDevicePanel {
        let asked = ContinuousClock.now
        for _ in 0..<2 {
            if let panel, panelReadAt >= asked - Self.panelMaxAge { return panel }
            await refreshPanel().value
        }
        if let panel {
            log(.info, "Mapping touches with the last display read: \(panelError.map { "\($0)" } ?? "no newer read")")
            return panel
        }
        throw panelError ?? IOSDeviceError.devicectlFailed("device info displays", udid: udid, detail: "it reported no display size")
    }

    /// The main display when it was read within `panelMaxAge`; otherwise nil, and a read starts for the next caller.
    public func freshGeometry() -> IOSDeviceGeometry? {
        if let geometry, ContinuousClock.now - panelReadAt <= Self.panelMaxAge { return geometry }
        refreshPanel()
        return nil
    }

    /// The screen turned: the next touch reads the display again, and a read already under way is discarded.
    public func displayChanged() {
        panelGeneration += 1
        panel = nil
        geometry = nil
    }

    /// The read under way, unless it started before the display last changed; otherwise a new one.
    @discardableResult
    private func refreshPanel() -> Task<Void, Never> {
        if let panelRefresh, refreshGeneration == panelGeneration { return panelRefresh }
        panelRefreshID += 1
        let id = panelRefreshID
        refreshGeneration = panelGeneration
        let task = Task {
            do {
                try await self.readPanel()
                self.panelError = nil
            } catch {
                self.panelError = error
            }
            if self.panelRefreshID == id { self.panelRefresh = nil }
        }
        panelRefresh = task
        return task
    }

    private func readPanel() async throws {
        let generation = panelGeneration
        let started = ContinuousClock.now
        let output = try await IOSDeviceDirectory(host: host).run(
            IOSDeviceSettings.readDisplays(udid: udid), label: "device info displays", udid: udid, timeout: IOSDeviceDirectory.infoTimeout
        )
        guard let read = IOSDevicePanel.parse(displaysJSON: Data(output.utf8)) else {
            throw IOSDeviceError.devicectlFailed("device info displays", udid: udid, detail: "it reported no display size")
        }
        guard generation == panelGeneration else { return }
        panel = read
        geometry = try? IOSDeviceGeometry.parse(Data(output.utf8))
        panelReadAt = started
    }

    /// The button socket, kept open; a fresh one waits out the activation floor so its first press is not dropped.
    private func buttonLink() async throws -> DeviceDTUHID {
        if let buttons { return buttons }
        if let buttonsOpening { return try await buttonsOpening.value }
        if let gone { throw gone }
        let task = Task { try await self.openButtons() }
        buttonsOpening = task
        defer { buttonsOpening = nil }
        return try await task.value
    }

    private func openButtons() async throws -> DeviceDTUHID {
        let reopening = buttonsTried
        buttonsTried = true
        let device = try await openTarget(reopening: reopening)
        guard let version, version.supportsHID else { throw IOSDeviceError.xcodeTooOld(device.name, version: version) }
        let link = try await DeviceDTUHID.connect(
            deviceIdentifier: device.identifier, feature: DTUHIDMessage.buttonService, version: version, name: device.name, udid: udid, anySent: false
        )
        let remaining = DTUHIDMessage.activationFloor - (ContinuousClock.now - link.firstMessageAt)
        if remaining > .zero { try await Task.sleep(for: remaining) }
        buttons = link
        return link
    }

    /// The broker's opening listing serves only a link's first open; any later one lists again, so it never reopens off USB.
    private func openTarget(reopening: Bool) async throws -> (identifier: String, name: String) {
        if !reopening, let target { return target }
        let device = try await currentDevice()
        return (device.identifier, device.name)
    }

    /// A barrier after the input proves the device read it; a link that fails it is dropped and opened again next time.
    private func confirm(_ link: DeviceDTUHID) async throws {
        let name = target?.name ?? udid
        switch await link.roundTrip(DTUHIDMessage.barrier(service: link.feature)) {
        case .answered:
            return
        case .refused(let error):
            buttons = nil
            await link.close()
            throw IOSDeviceError.barrierRefused(error, name: name, udid: udid, sent: true)
        case .connectionLost(let detail):
            buttons = nil
            throw IOSDeviceError.hidFailed(name, udid: udid, detail: "the button socket closed: \(detail)", sent: true)
        case .timedOut:
            buttons = nil
            await link.close()
            throw IOSDeviceError.hidFailed(name, udid: udid, detail: "the button socket did not confirm the press", sent: true)
        }
    }

    /// Only the stream that failed is dropped; it ends on the device in the background, before the next open starts.
    private func dropStream(_ dropped: IOSDeviceScreenStream, _ error: Error) {
        guard stream === dropped else { return }
        stream = nil
        lastAttempt = .now
        failure = (error as? IOSDeviceError) ?? IOSDeviceError.streamFailed(udid, udid: udid, detail: error.localizedDescription)
        let previous = streamClosing
        streamClosing = Task {
            await previous?.value
            await dropped.close()
        }
    }

    /// Never waits on the stream, which re-opens in the background with back-off; false only once a listing shows the device gone or off USB.
    public func checkHealth() async -> Bool {
        if gone != nil { return false }
        let now = ContinuousClock.now
        if now - lastUse < Self.activeWindow, panel == nil || now - panelReadAt > Self.panelInterval { refreshPanel() }
        if let stream {
            let frames = stream.framesReceived
            if frames != lastFrames {
                lastFrames = frames
                lastProgress = now
                return true
            }
            guard now - lastProgress > Self.stallLimit, opening == nil else { return true }
            log(.info, "Stream stalled at \(frames) frames; re-opening it")
            dropStream(stream, IOSDeviceError.streamFailed(target?.name ?? udid, udid: udid, detail: "the stream stopped delivering frames"))
            lastAttempt = .now - Self.reopenInterval
        }
        guard opening == nil else { return true }
        if failure?.kind == .streamNeedsGUISession {
            guard now - lastPresence > Self.presenceInterval else { return true }
            lastPresence = now
            return (try? await currentDevice()) != nil
        }
        if reopenDue { beginOpening() }
        return true
    }

    /// Releases anything still held, stops the stream on the device, which clears its screen-sharing indicator, and closes the button socket.
    public func close() async {
        closed = true
        if let hid { releaseHeldInput(hid) }
        if let button = heldButton, let buttons {
            buttons.send(DTUHIDMessage.button(usagePage: button.page, usage: button.code, state: .up))
            heldButton = nil
        }
        await opening?.value
        await streamClosing?.value
        if let stream {
            self.stream = nil
            await stream.close()
        }
        if let buttons {
            self.buttons = nil
            await buttons.close()
        }
        await panelRefresh?.value
        hid?.close()
        hid = nil
    }
}
