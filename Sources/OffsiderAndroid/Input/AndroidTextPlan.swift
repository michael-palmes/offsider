import Foundation

/// How `type` sends a string: all-ASCII text as key events, anything else pasted whole through the clipboard.
enum AndroidTextPlan: Equatable, Sendable {
    case keys([Chunk])
    case paste(String)

    enum Chunk: Equatable, Sendable {
        case text(String)
        case key(usage: UInt32)
    }

    static let maxChunkBytes = 256

    /// A burst over 31 key events overruns the guest kernel's 64-event input buffer, which then drops every key, so a run stays within 30.
    static let maxEmulatorKeyEvents = 30

    /// A down and an up per character, wrapped in Shift down and up for a shifted one, as the emulator and the helper send them.
    static func keyEvents(for scalar: Unicode.Scalar) -> Int {
        isShifted(scalar) ? 4 : 2
    }

    static func keyEvents(in text: some StringProtocol) -> Int {
        text.unicodeScalars.reduce(0) { $0 + keyEvents(for: $1) }
    }

    private static func isShifted(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || #"~!@#$%^&*()_+{}|:"<>?"#.unicodeScalars.contains(scalar)
    }

    /// One emulator `text` event or key press, and whether the guest must first take the keys sent before it.
    struct EmulatorSend: Equatable, Sendable {
        let event: EmulatorKeyEvent
        let afterDrain: Bool
        let characters: Int
    }

    /// Chunks as emulator events in bursts of at most `maxEmulatorKeyEvents` key events, Return and Tab as presses.
    static func emulatorSends(for chunks: [Chunk]) throws -> [EmulatorSend] {
        var sends: [EmulatorSend] = []
        var burst = 0
        func add(_ event: EmulatorKeyEvent, keyEvents: Int, characters: Int) {
            let afterDrain = burst + keyEvents > maxEmulatorKeyEvents
            if afterDrain { burst = 0 }
            sends.append(EmulatorSend(event: event, afterDrain: afterDrain, characters: characters))
            burst += keyEvents
        }
        for chunk in chunks {
            switch chunk {
            case .text(let run):
                for part in emulatorRuns(run) {
                    add(.text(part), keyEvents: keyEvents(in: part), characters: part.unicodeScalars.count)
                }
            case .key(let usage):
                guard let key = AndroidKeyTable.grpcKey(for: usage, phase: .press) else { throw AndroidError.unsupportedKey(usage) }
                add(key, keyEvents: 2, characters: 1)
            }
        }
        return sends
    }

    /// One ASCII run as emulator `text` events, in order, each at most `maxEmulatorKeyEvents` key events.
    static func emulatorRuns(_ run: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var events = 0
        for scalar in run.unicodeScalars {
            let cost = keyEvents(for: scalar)
            if events + cost > maxEmulatorKeyEvents {
                runs.append(current)
                current = ""
                events = 0
            }
            current.unicodeScalars.append(scalar)
            events += cost
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// `\n` (or `\r\n`) is Return and `\t` is Tab; any other control character fails before anything is typed.
    static func make(for text: String) throws -> AndroidTextPlan {
        let scalars = Array(text.unicodeScalars)
        if scalars.contains(where: { !$0.isASCII }) {
            return .paste(text)
        }
        var chunks: [Chunk] = []
        var run = ""
        func flush() {
            if !run.isEmpty {
                chunks.append(.text(run))
                run = ""
            }
        }
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x20...0x7E:
                run.unicodeScalars.append(scalar)
                if run.utf8.count == maxChunkBytes { flush() }
            case 0x0A:
                flush()
                chunks.append(.key(usage: 40))
            case 0x0D where index + 1 < scalars.count && scalars[index + 1] == "\n":
                continue
            case 0x09:
                flush()
                chunks.append(.key(usage: 43))
            default:
                throw AndroidError.unsupportedControlCharacter(scalar)
            }
        }
        flush()
        return .keys(chunks)
    }
}
