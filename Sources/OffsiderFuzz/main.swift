import Foundation
import OffsiderCore

// A mutation fuzzer run under AddressSanitizer, since Xcode's toolchain ships no libFuzzer runtime; usage in CONTRIBUTING.md.

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

enum Mutator {
    static let maxLength = 64 * 1024
    static let interesting: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xFF, 0x22, 0x5C, 0x3C, 0x3E, 0x7B, 0x7D, 0x5B, 0x5D, 0x0A, 0x30, 0x39]

    static func mutate(_ input: Data, corpus: [Data], random: inout SplitMix64) -> Data {
        var bytes = [UInt8](input)
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            switch Int.random(in: 0..<8, using: &random) {
            case 0 where !bytes.isEmpty:
                let index = Int.random(in: 0..<bytes.count, using: &random)
                bytes[index] ^= 1 << UInt8.random(in: 0..<8, using: &random)
            case 1 where !bytes.isEmpty:
                bytes[Int.random(in: 0..<bytes.count, using: &random)] = interesting.randomElement(using: &random)!
            case 2:
                let at = Int.random(in: 0...bytes.count, using: &random)
                bytes.insert(contentsOf: (0..<Int.random(in: 1...16, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }, at: at)
            case 3 where !bytes.isEmpty:
                let start = Int.random(in: 0..<bytes.count, using: &random)
                bytes.removeSubrange(start..<min(bytes.count, start + Int.random(in: 1...32, using: &random)))
            case 4 where !bytes.isEmpty:
                let start = Int.random(in: 0..<bytes.count, using: &random)
                let slice = bytes[start..<min(bytes.count, start + Int.random(in: 1...64, using: &random))]
                bytes.insert(contentsOf: slice, at: Int.random(in: 0...bytes.count, using: &random))
            case 5:
                let other = [UInt8](corpus.randomElement(using: &random) ?? Data())
                guard !other.isEmpty else { break }
                let cut = Int.random(in: 0...bytes.count, using: &random)
                bytes = Array(bytes[..<cut]) + other[Int.random(in: 0..<other.count, using: &random)...]
            case 6 where !bytes.isEmpty:
                bytes.removeLast(Int.random(in: 1...bytes.count, using: &random))
            case 7 where bytes.count >= 4:
                let at = Int.random(in: 0...(bytes.count - 4), using: &random)
                let word = [UInt32.max, 0x7FFF_FFFF, 0x8000_0000, 0x10000, 0].randomElement(using: &random)!
                for offset in 0..<4 { bytes[at + offset] = UInt8(truncatingIfNeeded: word >> (8 * offset)) }
            default:
                break
            }
        }
        return Data(bytes.prefix(maxLength))
    }
}

func files(in paths: [String]) -> [URL] {
    paths.flatMap { path -> [URL] in
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { url.appendingPathComponent($0) }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--list" {
    print(FuzzTargets.all.keys.sorted().joined(separator: "\n"))
    exit(0)
}
let targetName: String
if let first = arguments.first, FuzzTargets.all[first] != nil {
    targetName = arguments.removeFirst()
} else if let named = ProcessInfo.processInfo.environment["OFFSIDER_FUZZ_TARGET"], FuzzTargets.all[named] != nil {
    targetName = named
} else {
    fail("Name a target: OffsiderFuzz --list shows them.")
}
let target = FuzzTargets.all[targetName]!

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let found = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return found
}

if let index = arguments.firstIndex(of: "--replay") {
    let inputs = files(in: Array(arguments[(index + 1)...]))
    var parsed = 0
    for url in inputs {
        let ok = target(UntrustedRead.contents(atPath: url.path, maxBytes: Mutator.maxLength, truncate: true) ?? Data())
        print("\(ok ? "parsed" : "refused") \(url.lastPathComponent)")
        if ok { parsed += 1 }
    }
    print("\(targetName): replayed \(inputs.count) inputs, \(parsed) parsed")
    exit(0)
}

let seconds = value(after: "--seconds").flatMap(Double.init) ?? 60
let artifacts = URL(fileURLWithPath: value(after: "--artifacts") ?? FileManager.default.currentDirectoryPath)
let seed = value(after: "--seed").flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64.max)
guard let corpusPath = arguments.first else { fail("Name a corpus folder: OffsiderFuzz \(targetName) Tests/Fixtures/fuzz/\(targetName)") }
let corpus = files(in: [corpusPath]).compactMap { UntrustedRead.contents(atPath: $0.path, maxBytes: Mutator.maxLength, truncate: true) }
guard !corpus.isEmpty else { fail("No seeds in \(corpusPath).") }

try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
let pending = artifacts.appendingPathComponent("crash-\(targetName)")
print("\(targetName): \(corpus.count) seeds, \(Int(seconds)) s, seed \(seed)")

var random = SplitMix64(state: seed)
let deadline = Date().addingTimeInterval(seconds)
var runs = 0
for input in corpus {
    try? input.write(to: pending)
    _ = target(input)
}
while Date() < deadline {
    for _ in 0..<256 {
        let input = Mutator.mutate(corpus.randomElement(using: &random)!, corpus: corpus, random: &random)
        try? input.write(to: pending)
        _ = target(input)
        runs += 1
    }
}
try? FileManager.default.removeItem(at: pending)
print("\(targetName): \(runs) runs, no crash")
