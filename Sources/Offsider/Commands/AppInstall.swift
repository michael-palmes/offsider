import ArgumentParser
import Foundation
import OffsiderCore

struct AppInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an APK or a built .app, checked against the app it declares.",
        discussion: """
        The device decides the file: an .apk on Android, a built .app folder on an iPhone, iPad or simulator. Offsider \
        reads the app's id from the file on the Mac before sending anything and refuses one that is not --app. On an \
        emulator, a simulator or a test device --app defaults to the file's own id. On a phone, iPhone or iPad the app \
        must be pinned by name: allowing any app is not enough. Replaces an installed copy and keeps its data.

        Android checks the same package itself (`cmd package install --pkg`); an app signed differently is refused and \
        named. Split APKs and .aab bundles are not installed.

        iOS: Offsider installs a private copy of the .app it has checked, and never builds, signs or registers a \
        device. An .ipa, a simulator build for a device and a build whose profile does not cover the device are \
        refused before anything is sent. Over an App Store or TestFlight copy, an iPhone or iPad in personal use needs \
        a person at the Mac (Touch ID).

        Examples:
          offsider app install build/app-debug.apk --app com.example.app --device DEVICE_ID
          offsider app install Build/Products/Debug-iphoneos/Example.app --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("The .apk file (Android) or the built .app folder (iOS).", valueName: "path"))
    var path: String

    @OptionGroup
    var appOption: AppTargetOption

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    @MainActor
    func run() async throws {
        switch DeviceIDClassifier.classify(deviceOption.id) {
        case .iosSimulator: try await installBundle(for: .simulator)
        case .iosDevice: try await installBundle(for: .device)
        default: try await installApk()
        }
    }

    @MainActor
    private func installApk() async throws {
        let file = try AppManagementSupport.open(path)
        let declared = try AppManagementSupport.package(of: file)
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppManagementSupport.installTarget(appOption, declared: declared, route: route)
        guard app == declared else { throw AppManagementSupport.mismatch(path, declared: declared, app: app) }
        try AppTarget.requirePinned(app, route: route, command: "install")
        let install = try await Console.current.progress("Installing \(app), \(AppManagementSupport.megabytes(file.size))") {
            let backend = try AppTarget.manager(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.installApp(file, as: app, on: id)
        }
        report(install, on: route.device)
    }

    @MainActor
    func report(_ install: AppInstall, on device: DeviceID) {
        DeviceActivityLedger.current.recordInput(on: device)
        let verb = install.replaced ? "Replaced" : "Installed"
        let text = json ? AppManagementReport.install(install, path: path, on: device) : "\(verb) \(install.app) (\(AppManagementSupport.megabytes(install.bytes)), \(install.milliseconds) ms)."
        DevicePersonView.emit(text, json: json, person: DevicePersonView.receipt("\(verb) \(install.app)", aside: "\(AppManagementSupport.megabytes(install.bytes)), \(install.milliseconds) ms"), console: .current)
    }
}

enum AppManagementSupport {
    /// The file names one app and the command another: nothing is sent.
    static func mismatch(_ path: String, declared: String, app: String) -> AppLifecycleError {
        AppLifecycleError(.packageMismatch, "\(path) is \(declared), not \(app), so nothing was sent. Build \(app), or pass --app \(declared) if that app is allowed here.")
    }

    /// Before routing, so an iOS device is refused without starting its stack.
    static func requireAndroid(_ id: String, command: String) throws {
        switch DeviceIDClassifier.classify(id) {
        case .iosSimulator, .iosDevice:
            throw CLIError(errorDescription: "\(command) is Android only, and \(id) is an iOS device. Nothing was sent.", reason: .notSupported)
        default:
            break
        }
    }

    /// `--app`, else the file's own app where it is allowed by name or any app is, else offsider.login.json's or the only pinned app, which then must match.
    @MainActor
    static func installTarget(_ option: AppTargetOption, declared: String, route: DeviceRouter.Route, gate: DevicePolicyGate = .current) throws -> String {
        let own = route.allowance.map { gate.policy().drivesWhole($0) || $0.pinnedApps.contains(declared) } ?? true
        return try AppTarget.resolve(AppTargetOption.named(option.bundleID ?? (own ? declared : nil)), route: route, command: "install", gate: gate)
    }

    static func open(_ path: String) throws -> ApkFile {
        do {
            return try ApkFile(path: path)
        } catch ApkFile.Failure.missing {
            throw AppLifecycleError(.apkUnreadable, "No file at \(path).")
        } catch ApkFile.Failure.notRegularFile {
            let bundle = (path as NSString).pathExtension.lowercased() == "app"
            throw AppLifecycleError(.apkUnreadable, bundle ? "\(path) is an iOS app, and an Android device takes an .apk file. Nothing was sent." : "\(path) is not a file.")
        } catch {
            throw AppLifecycleError(.apkUnreadable, "\(path) could not be opened.")
        }
    }

    static func package(of file: ApkFile) throws -> String {
        do {
            return try ApkManifest.package(of: file)
        } catch .noManifest {
            let bundle = file.path.lowercased().hasSuffix(".aab")
            throw AppLifecycleError(.apkUnreadable, "\(file.path) has no AndroidManifest.xml at its root, so it is not an APK\(bundle ? ": a bundle needs building into one first" : "").")
        } catch .twoManifests {
            throw AppLifecycleError(.apkUnreadable, "\(file.path) holds two AndroidManifest.xml entries, so Offsider will not trust either. Nothing was sent.")
        } catch .notZip {
            throw AppLifecycleError(.apkUnreadable, "\(file.path) is not an APK: Offsider could not read it as a zip file.")
        } catch .unreadableManifest {
            throw AppLifecycleError(.apkUnreadable, "Offsider could not read the package in \(file.path)'s manifest, so nothing was sent.")
        }
    }

    static func megabytes(_ bytes: Int) -> String {
        bytes < 1 << 20 ? "\(bytes / 1024) KB" : "\(bytes >> 20) MB"
    }
}

extension AppTargetOption {
    static func named(_ app: String?) -> AppTargetOption {
        var option = AppTargetOption()
        option.bundleID = app
        return option
    }
}
