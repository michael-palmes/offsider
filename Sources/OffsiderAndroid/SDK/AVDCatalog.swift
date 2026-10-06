import Foundation

struct AVDInfo: Equatable, Sendable {
    /// The file stem of `<name>.ini`: the ID users pass.
    let name: String
    let directory: URL
    let displayName: String?
    let apiLevel: Int?
    let abi: String?
    let deviceProfile: String?
    /// `hw.ramSize` in MB; nil when absent or unreadable.
    var ramMB: Int? = nil
}

/// The AVDs defined on this Mac, read from their `.ini` files; unreadable ones are skipped.
struct AVDCatalog {
    let host: AndroidHost

    /// ANDROID_AVD_HOME, then ANDROID_USER_HOME/avd, then ANDROID_EMULATOR_HOME/avd, then ~/.android/avd.
    static func home(host: AndroidHost) -> URL {
        if let path = host.variable("ANDROID_AVD_HOME") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        for variable in ["ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME"] {
            if let path = host.variable(variable) {
                return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("avd", isDirectory: true)
            }
        }
        return host.homeDirectory.appendingPathComponent(".android/avd", isDirectory: true)
    }

    func all() -> [AVDInfo] {
        let home = Self.home(host: host)
        return Self.names(in: home, host: host).compactMap { info(named: $0, home: home) }
    }

    /// Exact and case-sensitive, checked against the folder listing because the Mac's file system ignores case.
    func info(named name: String) -> AVDInfo? {
        let home = Self.home(host: host)
        guard Self.names(in: home, host: host).contains(name) else { return nil }
        return info(named: name, home: home)
    }

    private static func names(in home: URL, host: AndroidHost) -> [String] {
        host.files.contentsOfDirectory(atPath: home.path)
            .filter { $0.hasSuffix(".ini") && $0.count > ".ini".count }
            .map { String($0.dropLast(".ini".count)) }
            .sorted()
    }

    private func info(named name: String, home: URL) -> AVDInfo? {
        let pointerPath = home.appendingPathComponent("\(name).ini").path
        guard let pointerData = host.files.contents(atPath: pointerPath) else { return nil }
        let pointer = IniFile.parse(String(decoding: pointerData, as: UTF8.self))

        var candidates: [URL] = []
        if let path = pointer["path"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let relative = pointer["path.rel"], !relative.isEmpty {
            candidates.append(home.deletingLastPathComponent().appendingPathComponent(relative, isDirectory: true))
        }
        for directory in candidates {
            guard let configData = host.files.contents(atPath: directory.appendingPathComponent("config.ini").path) else { continue }
            let config = IniFile.parse(String(decoding: configData, as: UTF8.self))
            return AVDInfo(
                name: name,
                directory: directory,
                displayName: config["avd.ini.displayname"],
                apiLevel: Self.apiLevel(systemImage: config["image.sysdir.1"]) ?? Self.apiLevel(target: pointer["target"]),
                abi: config["abi.type"],
                deviceProfile: config["hw.device.name"],
                ramMB: Self.megabytes(config["hw.ramSize"])
            )
        }
        return nil
    }

    /// `system-images/android-36/google_apis_playstore/arm64-v8a/` gives 36.
    static func apiLevel(systemImage: String?) -> Int? {
        guard let systemImage else { return nil }
        for component in systemImage.split(separator: "/") where component.hasPrefix("android-") {
            return leadingInteger(component.dropFirst("android-".count))
        }
        return nil
    }

    /// `2048`, `2048M`, `2048MB` and `2G` give 2048; a bare number is MB, as the emulator reads it.
    static func megabytes(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).uppercased(), !value.isEmpty else { return nil }
        let digits = value.prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        switch value.dropFirst(digits.count) {
        case "", "M", "MB": return number
        case "G", "GB": return number * 1024
        default: return nil
        }
    }

    /// `target=android-36` gives 36.
    static func apiLevel(target: String?) -> Int? {
        guard let target, target.hasPrefix("android-") else { return nil }
        return leadingInteger(target.dropFirst("android-".count))
    }

    private static func leadingInteger(_ text: Substring) -> Int? {
        Int(text.prefix { $0.isASCII && $0.isNumber })
    }
}
