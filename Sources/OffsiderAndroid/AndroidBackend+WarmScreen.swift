import Foundation
import OffsiderCore

/// What a display status read of an emulator with one panel says until it restarts; its warm helper's broker keeps it, so later commands skip the shell.
struct WarmScreenFacts: Codable, Equatable, Sendable {
    /// The script that printed `status`; facts another build's script printed are ignored.
    let script: String
    /// `AndroidDisplayStatus.script`'s output: the device states, the committed one and the displays.
    let status: String
    /// Display 0's viewport `uniqueId`, when the command that read them probed it.
    let viewport: String?
    let apiLevel: Int?

    /// One built-in panel and fewer than two device states, so no fold or posture can change them.
    static func hold(states: [AndroidDeviceState.State], displays: AndroidDisplayList) -> Bool {
        states.count < 2 && displays.displays.filter { !$0.external }.count == 1
    }

    var encoded: String? {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    init(status: String, viewport: String?, apiLevel: Int?) {
        script = AndroidDisplayStatus.script
        self.status = status
        self.viewport = viewport
        self.apiLevel = apiLevel
    }

    /// Nil when unreadable or printed by another script.
    init?(encoded: String) {
        guard let facts = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)), facts.script == AndroidDisplayStatus.script else {
            return nil
        }
        self = facts
    }
}

/// Where this command's display facts for one serial came from.
enum ScreenFactsSource: Equatable, Sendable {
    /// From the warm helper's broker; `screenInfo` checks them against the measured geometry.
    case borrowed
    /// Read from the shell, and left with the warm helper when the command closes.
    case learnt(WarmScreenFacts)
    /// Read from the shell with nothing to leave, or borrowed and found not to fit: not borrowed again this command.
    case unusable
}

extension AndroidBackend {
    /// The warm helper's socket when `serial` is an emulator that keeps one; a phone always reads its displays from the shell.
    private func warmScreenSocket(_ serial: String) -> String? {
        guard phones[serial] == nil, HelperBrokerSettings.isEmulatorSerial(serial), (try? keepsHelperWarm(serial)) == true else { return nil }
        return warmHelperSocket(serial)
    }

    /// The facts the warm helper keeps for `serial`, asked once a command; nil when it keeps none.
    func borrowScreenFacts(_ serial: String) async -> WarmScreenFacts? {
        guard screenFacts[serial] == nil, let socket = warmScreenSocket(serial) else { return nil }
        let encoded = await host.timing.measure(.warmScreen) { await HelperBrokerClient.screen(at: socket) }
        guard let facts = encoded.flatMap(WarmScreenFacts.init(encoded:)) else { return nil }
        screenFacts[serial] = .borrowed
        return facts
    }

    /// After a shell read: the facts to leave with the warm helper when they hold for this device.
    func learnScreenFacts(_ serial: String, output: String, status: AndroidDisplayStatus.Parsed) {
        guard WarmScreenFacts.hold(states: status.states, displays: status.displays), warmScreenSocket(serial) != nil else {
            screenFacts[serial] = .unusable
            return
        }
        screenFacts[serial] = .learnt(WarmScreenFacts(
            status: AndroidDisplayStatus.withoutProbe(output), viewport: activeUniqueIds[serial], apiLevel: apiLevels[serial] ?? nil
        ))
    }

    /// True when the facts borrowed this command name a panel `geometry` does not fit; they are then forgotten and unusable.
    func dropsBorrowedScreenFacts(notFitting geometry: AndroidDisplayGeometry, on serial: String) -> Bool {
        guard screenFacts[serial] == .borrowed else { return false }
        if let active = displayLists[serial].flatMap({ activeDisplay(in: $0, serial: serial) }), geometry.fits(active.descriptor) {
            return false
        }
        log(.debug, "The display facts the warm helper kept for \(serial) do not fit its screen; reading them again")
        screenFacts[serial] = .unusable
        forgetDisplay(of: serial)
        return true
    }

    /// Leaves what this command learnt with each warm helper, once.
    func leaveScreenFacts() async {
        let learnt = screenFacts.sorted { $0.key < $1.key }
        screenFacts = [:]
        for case let (serial, .learnt(facts)) in learnt {
            guard let socket = warmScreenSocket(serial), let encoded = facts.encoded else { continue }
            if await HelperBrokerClient.rememberScreen(encoded, at: socket) {
                log(.debug, "Left the display facts of \(serial) with its warm helper")
            }
        }
    }
}
