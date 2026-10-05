import Foundation
import OffsiderCore

/// The broker's hold on one wired device: its UniversalHID service for touches and keys, its HID button socket and its screen stream.
@MainActor
public final class CoreDeviceSessionHardware: DeviceSessionHardware {
    /// A live stream that delivers no new frame for this long has died; a still screen keeps sending frames.
    static let stallLimit: Duration = .seconds(6)
    /// Failed re-opens in a row before the broker gives the device up.
    static let reopenLimit = 3
    static let reopenInterval: Duration = .seconds(5)
    static let presenceInterval: Duration = .seconds(30)
    /// The panel's orientation is read again this often while the broker is in use.
    static let panelInterval: Duration = .seconds(2)
    static let activeWindow: Duration = .seconds(60)
    static let touchscreenFallback: UInt64 = 257
    static let keyboardFallback: UInt64 = 512

    let udid: String
    let host: IOSDeviceHost
    let log: IOSDeviceLog
    private let version: CoreDeviceVersion?
    private var stream: IOSDeviceScreenStream?
    private var opening: Task<Void, Never>?
    private var failure: IOSDeviceError?
    private var buttons: DeviceDTUHID?
    private var target: (identifier: String, name: String)?
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
    private var surfaces: (touchscreen: UInt64, keyboard: UInt64) = (touchscreenFallback, keyboardFallback)
    private var panel: IOSDevicePanel?
    public private(set) var geometry: IOSDeviceGeometry?
    private var panelReadAt = ContinuousClock.now
    private var panelRefresh: Task<Void, Never>?
    private var lastUse = ContinuousClock.now

    public init(udid: String, host: IOSDeviceHost = .live(), version: CoreDeviceVersion? = CoreDeviceVersion.installed(), log: @escaping IOSDeviceLog) {
        self.udid = udid
        self.host = host
        self.version = version
        self.log = log
    }

    public var supportsTouch: Bool { version?.supportsHID == true && hidFailure == nil }

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
        await openStream()
        await input.value
    }

    private func openStream() async {
        if let opening { return await opening.value }
        let task = Task { await self.attemptOpen() }
        opening = task
        await task.value
        opening = nil
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

    /// A fresh listing each time, since the tunnel address changes when the tunnel comes back.
    private func currentDevice() async throws -> (identifier: String, name: String, tunnel: String?) {
        guard let device = try await IOSDeviceDirectory(host: host).device(udid: udid) else { throw IOSDeviceError.notListed(udid) }
        let name = DeviceName.display(device.udid, label: device.label)
        guard device.transportType == "wired", device.connectionState != "unavailable" else { throw IOSDeviceError.unavailable(name) }
        guard let identifier = device.coreDeviceIdentifier else {
            throw IOSDeviceError.streamFailed(name, udid: udid, detail: "devicectl did not report its CoreDevice identifier")
        }
        target = (identifier, name)
        return (identifier, name, device.tunnelAddress)
    }

    public func frame(_ format: IOSDeviceScreenFrame.Format) async throws -> IOSDeviceScreenFrame {
        lastUse = .now
        if stream == nil {
            if opening == nil, failure?.kind != .streamNeedsGUISession { await openStream() } else { await opening?.value }
        }
        guard let stream else {
            throw failure ?? IOSDeviceError.streamFailed(udid, udid: udid, detail: "the stream did not open")
        }
        do {
            return try await stream.latestFrame(format)
        } catch {
            await dropStream(error)
            throw error
        }
    }

    public func button(usagePage: UInt64, usageCode: UInt64, state: DeviceSessionRequest.ButtonState) async throws {
        lastUse = .now
        let link = try await buttonLink()
        link.send(DTUHIDMessage.button(usagePage: usagePage, usage: usageCode, state: state == .down ? .down : .up))
        try await confirm(link)
    }

    public func press(usagePage: UInt64, usageCode: UInt64, hold: Double) async throws {
        lastUse = .now
        let link = try await buttonLink()
        link.send(DTUHIDMessage.button(usagePage: usagePage, usage: usageCode, state: .down))
        try? await Task.sleep(for: .seconds(hold))
        link.send(DTUHIDMessage.button(usagePage: usagePage, usage: usageCode, state: .up))
        try await confirm(link)
    }

    public func touch(_ steps: [DeviceSessionStep]) async throws {
        lastUse = .now
        let reports = try DeviceSessionReports.touch(steps, panel: try await currentPanel())
        try await play(reports)
    }

    public func keys(_ steps: [DeviceSessionStep]) async throws {
        lastUse = .now
        try await play(try DeviceSessionReports.keys(steps))
    }

    /// Sends each report against a clock started at the first, so many short pauses keep the gesture's total time, then confirms delivery.
    private func play(_ reports: [DeviceSessionReport]) async throws {
        let service = try await hidService()
        let start = ContinuousClock.now
        var elapsed = 0.0
        for report in reports {
            switch report {
            case let .touch(x, y, state):
                service.send(UniversalHIDReport.touchscreen(x: x, y: y, state: state, timestamp: UniversalHIDReport.timestamp()), to: surfaces.touchscreen)
            case .keyboard(let pressed):
                service.send(UniversalHIDReport.keyboard(pressedUsages: pressed, timestamp: UniversalHIDReport.timestamp()), to: surfaces.keyboard)
            case .sleep(let seconds):
                elapsed += seconds
                let due = start + .seconds(elapsed)
                if due > .now { try? await Task.sleep(until: due, clock: .continuous) }
            }
        }
        do {
            try await service.confirm()
        } catch {
            hid = nil
            service.close()
            throw error
        }
    }

    /// The UniversalHID service, kept open; it waits out its own activation window once when it opens.
    private func hidService() async throws -> UniversalHIDService {
        if let hid { return hid }
        if let hidOpening { return try await hidOpening.value }
        let task = Task { try await self.openHID() }
        hidOpening = task
        defer { hidOpening = nil }
        return try await task.value
    }

    private func openHID() async throws -> UniversalHIDService {
        do {
            let device = try await resolvedTarget()
            guard let version, version.supportsHID else { throw IOSDeviceError.xcodeTooOld(device.name, version: version) }
            let service = try await UniversalHIDService.connect(deviceIdentifier: device.identifier, version: version, name: device.name, udid: udid)
            let listed = try await service.connectedServices()
            surfaces = (listed.first(.touchscreen)?.id ?? Self.touchscreenFallback, listed.first(.keyboard)?.id ?? Self.keyboardFallback)
            hid = service
            hidFailure = nil
            log(.info, "UniversalHID open: touchscreen \(surfaces.touchscreen), keyboard \(surfaces.keyboard)")
            return service
        } catch {
            hidFailure = error as? IOSDeviceError
            throw error
        }
    }

    /// The cached panel, read again in the background once it is older than `panelInterval`; the first read waits.
    private func currentPanel() async throws -> IOSDevicePanel {
        if let panel {
            if ContinuousClock.now - panelReadAt > Self.panelInterval { refreshPanelSoon() }
            return panel
        }
        try await readPanel()
        guard let panel else { throw IOSDeviceError.devicectlFailed("device info displays", udid: udid, detail: "it reported no display size") }
        return panel
    }

    private func refreshPanelSoon() {
        guard panelRefresh == nil else { return }
        panelRefresh = Task {
            try? await self.readPanel()
            self.panelRefresh = nil
        }
    }

    private func readPanel() async throws {
        let output = try await IOSDeviceDirectory(host: host).run(
            IOSDeviceSettings.readDisplays(udid: udid), label: "device info displays", udid: udid, timeout: IOSDeviceDirectory.infoTimeout
        )
        guard let read = IOSDevicePanel.parse(displaysJSON: Data(output.utf8)) else {
            throw IOSDeviceError.devicectlFailed("device info displays", udid: udid, detail: "it reported no display size")
        }
        panel = read
        geometry = try? IOSDeviceGeometry.parse(Data(output.utf8))
        panelReadAt = .now
    }

    /// The button socket, kept open; a fresh one waits out the activation floor so its first press is not dropped.
    private func buttonLink() async throws -> DeviceDTUHID {
        if let buttons { return buttons }
        if let buttonsOpening { return try await buttonsOpening.value }
        let task = Task { try await self.openButtons() }
        buttonsOpening = task
        defer { buttonsOpening = nil }
        return try await task.value
    }

    private func openButtons() async throws -> DeviceDTUHID {
        let device = try await resolvedTarget()
        guard let version, version.supportsHID else { throw IOSDeviceError.xcodeTooOld(device.name, version: version) }
        let link = try await DeviceDTUHID.connect(
            deviceIdentifier: device.identifier, feature: DTUHIDMessage.buttonService, version: version, name: device.name, udid: udid, anySent: false
        )
        let remaining = DTUHIDMessage.activationFloor - (ContinuousClock.now - link.firstMessageAt)
        if remaining > .zero { try await Task.sleep(for: remaining) }
        buttons = link
        return link
    }

    private func resolvedTarget() async throws -> (identifier: String, name: String) {
        if let target { return target }
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

    private func dropStream(_ error: Error) async {
        guard let stream else { return }
        self.stream = nil
        failure = (error as? IOSDeviceError) ?? IOSDeviceError.streamFailed(udid, udid: udid, detail: error.localizedDescription)
        await stream.close()
    }

    /// A live stream must keep delivering frames; a dead one is re-opened, and a device that stays unreachable ends the broker.
    public func checkHealth() async -> Bool {
        let now = ContinuousClock.now
        if now - lastUse < Self.activeWindow, panel == nil || now - panelReadAt > Self.panelInterval { refreshPanelSoon() }
        if let stream {
            let frames = stream.framesReceived
            if frames != lastFrames {
                lastFrames = frames
                lastProgress = now
                return true
            }
            guard now - lastProgress > Self.stallLimit, opening == nil else { return true }
            log(.info, "Stream stalled at \(frames) frames; re-opening it")
            await dropStream(IOSDeviceError.streamFailed(target?.name ?? udid, udid: udid, detail: "the stream stopped delivering frames"))
        }
        guard opening == nil else { return true }
        if failure?.kind == .streamNeedsGUISession {
            guard now - lastPresence > Self.presenceInterval else { return true }
            lastPresence = now
            return (try? await currentDevice()) != nil
        }
        if let failure, [.notListed, .unavailable].contains(failure.kind) { return false }
        guard failedReopens < Self.reopenLimit else { return false }
        guard now - lastAttempt >= Self.reopenInterval else { return true }
        await openStream()
        if let failure, [.notListed, .unavailable].contains(failure.kind) { return false }
        return true
    }

    /// Stops the stream on the device, which clears its screen-sharing indicator, and closes the button socket.
    public func close() async {
        closed = true
        await opening?.value
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
