import Foundation

/// Pure verdicts for `doctor --device <iPhone UDID>`, and the order and dependency skips they report in.
public enum IOSDeviceDoctorRules {
    public typealias Verdict = DoctorRules.Verdict

    public static let minimumXcodeMajor = 26
    public static let hidXcodeMajor = 27
    /// The first CoreDevice whose disk image carries the HID daemon.
    public static let hidCoreDeviceVersion = "636"

    public static func checks(_ facts: IOSDeviceDoctorFacts) -> [DoctorCheckResult] {
        var checks = [DoctorCheckResult(id: .iosDeviceXcode, verdict: xcode(facts.xcode))]
        checks += deviceChecks(facts)
        checks.append(DoctorCheckResult(id: .iosDeviceUsbmuxd, verdict: usbmuxd(facts.usbmuxdSocket)))
        checks.append(DoctorCheckResult(id: .iosDeviceRunnerSigning, verdict: runnerSigning(facts.team)))
        return checks
    }

    /// Whether `--fix` should mount the developer disk image.
    public static func isDDIFixable(_ facts: IOSDeviceDoctorFacts) -> Bool {
        guard let row = facts.row, row.isConnected, row.pairingState == "paired", row.developerModeStatus == "enabled" else { return false }
        return row.ddiServicesAvailable == false
    }

    private static let chain: [DoctorCheckID] = [
        .iosDeviceCoreDevice, .iosDeviceListed, .iosDeviceTransport, .iosDevicePairing, .iosDeviceDeveloperMode, .iosDeviceDDI, .iosDeviceTunnel, .iosDeviceLockState,
        .iosDeviceHID, .iosDeviceUIAutomation,
    ]

    static func deviceChecks(_ facts: IOSDeviceDoctorFacts) -> [DoctorCheckResult] {
        func skipping(from id: DoctorCheckID, because blocker: DoctorCheckID) -> [DoctorCheckResult] {
            chain.drop { $0 != id }.map { DoctorCheckResult.skipped($0, "requires \(blocker.rawValue)") }
        }
        guard case .found = facts.xcode, let listing = facts.listing else {
            return skipping(from: .iosDeviceCoreDevice, because: .iosDeviceXcode)
        }
        let core = coreDevice(facts.coreDeviceVersion, listing: listing)
        var checks = [DoctorCheckResult(id: .iosDeviceCoreDevice, verdict: core)]
        guard core.status != .fail else {
            return checks + skipping(from: .iosDeviceListed, because: .iosDeviceCoreDevice)
        }
        guard let row = facts.row else {
            checks.append(DoctorCheckResult(id: .iosDeviceListed, status: .fail, detail: "\(facts.udid) is not known to this Mac", hint: "Connect it with a cable, unlock it and tap Trust when it asks."))
            return checks + skipping(from: .iosDeviceTransport, because: .iosDeviceListed)
        }
        checks.append(DoctorCheckResult(id: .iosDeviceListed, status: .pass, detail: listedDetail(row, udid: facts.udid)))
        let transportVerdict = transport(row)
        checks.append(DoctorCheckResult(id: .iosDeviceTransport, verdict: transportVerdict))
        guard row.isConnected else {
            return checks + skipping(from: .iosDevicePairing, because: .iosDeviceTransport)
        }
        let pairingVerdict = pairing(row.pairingState)
        checks.append(DoctorCheckResult(id: .iosDevicePairing, verdict: pairingVerdict))
        guard pairingVerdict.status == .pass else {
            return checks + skipping(from: .iosDeviceDeveloperMode, because: .iosDevicePairing)
        }
        let modeVerdict = developerMode(row.developerModeStatus)
        checks.append(DoctorCheckResult(id: .iosDeviceDeveloperMode, verdict: modeVerdict))
        if modeVerdict.status == .pass {
            let ddiVerdict = ddi(row, udid: facts.udid)
            checks.append(DoctorCheckResult(id: .iosDeviceDDI, verdict: ddiVerdict, fixable: ddiVerdict.status == .warn))
            checks.append(DoctorCheckResult(id: .iosDeviceTunnel, verdict: tunnel(row.tunnelState)))
        } else {
            checks += [.iosDeviceDDI, .iosDeviceTunnel].map { DoctorCheckResult.skipped($0, "requires \(DoctorCheckID.iosDeviceDeveloperMode.rawValue)") }
        }
        checks.append(DoctorCheckResult(id: .iosDeviceLockState, verdict: lockState(facts.lock)))
        guard modeVerdict.status == .pass else {
            return checks + [.iosDeviceHID, .iosDeviceUIAutomation].map { DoctorCheckResult.skipped($0, "requires \(DoctorCheckID.iosDeviceDeveloperMode.rawValue)") }
        }
        checks.append(DoctorCheckResult(id: .iosDeviceHID, verdict: hid(facts.hid)))
        checks.append(DoctorCheckResult(id: .iosDeviceUIAutomation, verdict: uiAutomation(facts.hid)))
        return checks
    }

    // MARK: Verdicts

    public static func xcode(_ fact: IOSDeviceDoctorFacts.XcodeFact) -> Verdict {
        switch fact {
        case .notFound(let message):
            return (.fail, message, "Select Xcode with xcode-select -s <Xcode.app>/Contents/Developer.")
        case .found(let developerDir, let version, let build):
            let description = "Xcode \(version ?? "unknown")" + (build.map { " (\($0))" } ?? "") + " at \(developerDir)"
            guard let major = DoctorRules.majorVersion(version) else {
                return (.warn, description, "Could not read the Xcode version; iPhones need Xcode \(minimumXcodeMajor) or later.")
            }
            if major < minimumXcodeMajor {
                return (.fail, description, "iPhones need Xcode \(minimumXcodeMajor) or later; Xcode \(hidXcodeMajor) for keys, gestures and buttons.")
            }
            if major < hidXcodeMajor {
                return (.warn, description + "; taps and the accessibility tree only", "Keys, gestures and most buttons on an iPhone need Xcode \(hidXcodeMajor).")
            }
            return (.pass, description, nil)
        }
    }

    public static func coreDevice(_ version: String?, listing: IOSDeviceDoctorFacts.ListingFact) -> Verdict {
        if case .failed(let message) = listing {
            return (.fail, "devicectl did not list devices: \(message)", "Run xcodebuild -runFirstLaunch, then retry.")
        }
        guard let version else {
            return (.warn, "devicectl did not report its CoreDevice version", nil)
        }
        if let current = DoctorRules.versionComponents(version), let floor = DoctorRules.versionComponents(hidCoreDeviceVersion),
           current.lexicographicallyPrecedes(floor) {
            return (.warn, "CoreDevice \(version)", "HID input on an iPhone needs CoreDevice \(hidCoreDeviceVersion) or later (Xcode \(hidXcodeMajor)).")
        }
        return (.pass, "CoreDevice \(version)", nil)
    }

    static func listedDetail(_ row: IOSDeviceDoctorRow, udid: String) -> String {
        DeviceName.display(udid, label: row.label) + (row.osVersion.map { ", iOS \($0)" } ?? "")
    }

    public static func transport(_ row: IOSDeviceDoctorRow) -> Verdict {
        guard row.isConnected else {
            return (.fail, "Paired with this Mac but not connected", "Connect its cable and unlock it.")
        }
        switch row.transportType {
        case "wired":
            return (.pass, "USB", nil)
        case "localNetwork":
            return (.fail, "Wi-Fi only", "Connect its cable: Offsider drives iPhones and iPads over USB only.")
        default:
            return (.fail, "Connected over \(row.transportType ?? "an unknown transport")", "Connect its cable: Offsider drives iPhones and iPads over USB only.")
        }
    }

    public static func pairing(_ state: String?) -> Verdict {
        state == "paired"
            ? (.pass, "Trusts this Mac", nil)
            : (.fail, "Does not trust this Mac (\(state ?? "unknown"))", "Unlock it and tap Trust when it asks. Offsider never pairs a device itself.")
    }

    public static func developerMode(_ status: String?) -> Verdict {
        status == "enabled"
            ? (.pass, "On", nil)
            : (.fail, "Off", "Turn it on in Settings > Privacy & Security > Developer Mode, then restart the device.")
    }

    public static func ddi(_ row: IOSDeviceDoctorRow, udid: String) -> Verdict {
        switch row.ddiServicesAvailable {
        case true?:
            return (.pass, "Developer services available", nil)
        case false? where row.deviceSupportFinalized:
            return (.warn, "Developer services are reconnecting", "Run offsider doctor --device \(udid) --fix, or any Offsider command, to bring them back.")
        case false?:
            return (.warn, "Xcode is preparing the device for development", "Keep it connected and unlocked, or run offsider doctor --device \(udid) --fix to mount the developer disk image.")
        case nil:
            return (.skip, "not reported by this Xcode", nil)
        }
    }

    public static func tunnel(_ state: String?) -> Verdict {
        switch state {
        case "connected"?:
            return (.pass, "Connected", nil)
        case let state?:
            return (.warn, "The CoreDevice tunnel is \(state)", "Offsider brings it up on the next command; if that fails, reconnect the cable.")
        case nil:
            return (.skip, "not reported by this Xcode", nil)
        }
    }

    /// `lockState` has no "locked now" flag, so a dark screen with a passcode only reads as probably locked.
    public static func lockState(_ fact: IOSDeviceDoctorFacts.LockFact?) -> Verdict {
        switch fact {
        case nil:
            return (.skip, "the device did not answer", nil)
        case .unreadable(let message)?:
            return (.skip, "could not read it: \(message)", nil)
        case .read(let passcodeRequired, let backlightOn)?:
            switch (backlightOn, passcodeRequired) {
            case (true?, _):
                return (.pass, "Screen on", nil)
            case (false?, true?):
                return (.warn, "Probably locked: the screen is off and a passcode is set", "Unlock it before driving it; Offsider never types an iPhone passcode.")
            case (false?, _):
                return (.warn, "The screen is off", "Wake it before driving it.")
            case (nil, _):
                return (.skip, "the device did not report its screen state", nil)
            }
        }
    }

    static let uiAutomationPath = "Settings > Developer > UI Automation"

    /// The digitizer socket and a barrier on it; below CoreDevice 636 nothing is asked of the device.
    public static func hid(_ fact: IOSDeviceDoctorFacts.HIDFact?) -> Verdict {
        switch fact {
        case nil:
            return (.skip, "not checked: the developer services were not available", nil)
        case .unsupported(let version)?:
            return (.skip, "CoreDevice \(version ?? "unknown") has no HID input", "Install Xcode \(hidXcodeMajor) for HID input on an iPhone or iPad.")
        case .locked?:
            return (.fail, "The device is locked, so it refuses HID input", "Unlock the iPhone or iPad, then retry. Offsider never types a passcode.")
        case .socketFailed(let message)?:
            return (.fail, "CoreDevice did not open the digitizer: \(message)", "Reconnect the cable and unlock the device, then retry.")
        case .unresponsive(let message)?:
            return (.fail, "The digitizer opened but \(message)", "Reconnect the cable, then retry.")
        case .refused?:
            return (.fail, "The device refused HID input while unlocked", "Turn on \(uiAutomationPath).")
        case .ready?:
            return (.pass, "The digitizer answered", nil)
        }
    }

    /// iOS reports no setting for it, so only a refused probe on an unlocked device shows it is off.
    public static func uiAutomation(_ fact: IOSDeviceDoctorFacts.HIDFact?) -> Verdict {
        if case .refused? = fact {
            return (.fail, "Probably off: the device refused input while unlocked", "Turn on \(uiAutomationPath).")
        }
        return (.skip, "not readable; it must be on in \(uiAutomationPath)", nil)
    }

    public static func usbmuxd(_ socketExists: Bool) -> Verdict {
        socketExists
            ? (.pass, "/var/run/usbmuxd is present", nil)
            : (.fail, "/var/run/usbmuxd is missing, so nothing can reach a device over USB", "Reconnect the cable; restart the Mac if it stays missing.")
    }

    public static func runnerSigning(_ fact: IOSDeviceDoctorFacts.TeamFact) -> Verdict {
        switch fact {
        case .environment(let team):
            guard team.count == 10, team.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) }), team.allSatisfy(\.isASCII) else {
                return (.fail, "OFFSIDER_IOS_TEAM_ID is not a 10-character team ID", "Set it to the team ID from Xcode's Signing & Capabilities, or unset it.")
            }
            return (.pass, "Team \(team) from OFFSIDER_IOS_TEAM_ID", nil)
        case .xcodeTeams(let teams):
            switch teams.count {
            case 0:
                return (.warn, "No team is signed in to Xcode", "Sign in to Xcode with an Apple Account, or set OFFSIDER_IOS_TEAM_ID.")
            case 1:
                return (.pass, "Team \(teams[0]), the only one signed in to Xcode", nil)
            default:
                return (.warn, "Xcode has \(teams.count) teams signed in", "Set OFFSIDER_IOS_TEAM_ID to one of \(teams.sorted().joined(separator: ", ")).")
            }
        }
    }
}
