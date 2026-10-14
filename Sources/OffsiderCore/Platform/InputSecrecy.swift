import Foundation

/// Marks text that must never reach a process argument on the device, such as a password `login` types.
public enum InputSecrecy {
    @TaskLocal public static var isSecret = false
}
