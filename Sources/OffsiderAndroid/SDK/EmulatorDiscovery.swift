import Foundation

/// A running emulator's `pid_<pid>.ini`; undocumented, measured on emulator 36.4.9 and 37.1.11.
struct EmulatorDiscovery: Equatable, Sendable, CustomStringConvertible {
    let path: String
    let pid: Int32
    let values: [String: String]

    var consolePort: Int? { values["port.serial"].flatMap { Int($0) } }
    var grpcPort: Int? { values["grpc.port"].flatMap { Int($0) } }
    var token: String? { values["grpc.token"] }
    var avdID: String? { values["avd.id"] }
    var jwksDirectory: String? { values["grpc.jwks"] }
    var jwkActivePath: String? { values["grpc.jwk_active"] }
    var allowlistPath: String? { values["grpc.allowlist"] }
    var emulatorVersion: String? { values["emulator.version"] }

    /// Never prints the gRPC token.
    var description: String {
        let fields = values.keys.sorted().map { key in "\(key)=\(key == "grpc.token" ? "<redacted>" : values[key] ?? "")" }
        return "\(path) (pid \(pid)): " + fields.joined(separator: ", ")
    }

    struct NotADiscoveryFile: Error {}

    /// Only `pid_<digits>.ini`; the emulator's help text says `pid_%d_info.ini`, which it does not write.
    static func parse(fileName: String, directory: String = "", contents: String) throws -> EmulatorDiscovery {
        guard fileName.hasPrefix("pid_"), fileName.hasSuffix(".ini") else { throw NotADiscoveryFile() }
        let digits = fileName.dropFirst("pid_".count).dropLast(".ini".count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = Int32(digits) else {
            throw NotADiscoveryFile()
        }
        let path = directory.isEmpty ? fileName : (directory as NSString).appendingPathComponent(fileName)
        return EmulatorDiscovery(path: path, pid: pid, values: IniFile.parse(contents))
    }

    static func directory(host: AndroidHost) -> URL {
        host.homeDirectory.appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true)
    }

    /// Files whose pid is alive; a file that vanishes or fails to parse mid-scan is skipped.
    static func live(host: AndroidHost) -> [EmulatorDiscovery] {
        let directory = directory(host: host).path
        return host.files.contentsOfDirectory(atPath: directory).sorted().compactMap { name in
            guard let data = host.files.contents(atPath: (directory as NSString).appendingPathComponent(name)),
                  let discovery = try? parse(fileName: name, directory: directory, contents: String(decoding: data, as: UTF8.self)),
                  host.isProcessAlive(discovery.pid) else {
                return nil
            }
            return discovery
        }
    }
}
