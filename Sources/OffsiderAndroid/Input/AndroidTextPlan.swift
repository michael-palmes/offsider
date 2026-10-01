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
