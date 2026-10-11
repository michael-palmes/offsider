import Foundation

/// React Native's LogBox inspector, open in its own window, hides the app from the tree, so a selector that matched nothing cannot match until it closes.
public struct LogBoxBlock: Equatable, Sendable {
    /// The selector, as `--label 'Retry'`.
    public var subject: String
    /// The inspector shows its Minimize button.
    public var minimize: Bool

    public init(subject: String, minimize: Bool) {
        self.subject = subject
        self.minimize = minimize
    }

    /// The block `tree` shows for `subject`, given the inspector already read from it; nil while the app is in the tree.
    public static func hiding(_ tree: UITree, inspector: LogBoxInspector?, subject: String) -> LogBoxBlock? {
        guard let inspector, tree.context.window?.kind == .modal else { return nil }
        return LogBoxBlock(subject: subject, minimize: inspector.minimize != nil)
    }

    /// What a read it blocked reports.
    public static let reason = "not found; LogBox inspector open"
}

/// A selector wait or check stopped because the LogBox inspector kept the app out of the tree.
public struct WaitBlockedError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let block: LogBoxBlock
    /// A `--gone` wait, which cannot tell gone from hidden.
    public let gone: Bool

    /// How long a block must hold, over two reads or more, before a wait stops early.
    public static let grace: TimeInterval = 1.5

    public init(block: LogBoxBlock, gone: Bool) {
        self.block = block
        self.gone = gone
    }

    public var message: String {
        let outcome = gone ? "Offsider cannot tell whether \(block.subject) is gone" : "\(block.subject) cannot appear"
        return "The React Native LogBox inspector is open in its own window, which hides the app on Android, so \(outcome). Close it, then try again."
    }

    public var hint: String? {
        block.minimize ? "offsider tap --label Minimize --device <DEVICE_ID>" : "offsider rn logbox dismiss --device <DEVICE_ID>"
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}
