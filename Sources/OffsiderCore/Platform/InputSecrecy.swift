import Foundation

/// Marks text that must never reach a process argument on the device, such as a password `login` types.
public enum InputSecrecy {
    @TaskLocal public static var isSecret = false
    /// Text given as a command argument: when the focused field cannot be read, it is typed as a password would be.
    @TaskLocal public static var fromArgument = false
    /// The focused-field verdict the command read just before typing; nil lets the input session read the screen itself.
    @TaskLocal public static var knownFocus: KnownSecureFocus?
}

/// Whether a password field had focus when the command last read the screen.
public enum KnownSecureFocus: Equatable, Sendable {
    case secure
    case notSecure
    /// The screen could not be read.
    case unknown
}
