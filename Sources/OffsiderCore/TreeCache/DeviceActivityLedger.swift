import Foundation

/// What one command did to each device: its last full tree read and its last input, for the tree cache written at exit.
@MainActor
public final class DeviceActivityLedger {
    /// One per process; a test binds its own so parallel tests do not share one.
    @TaskLocal public static var current = DeviceActivityLedger()

    public struct Activity: Equatable, Sendable {
        public let device: DeviceID
        public var firstReadStartedAt: Date?
        public var tree: UITree?
        public var treeReadAt: Date?
        public var screen: UIScreenInfo?
        public var lastInputAt: Date?
        /// Every node of the last gap fill's tree; never written to a file.
        public var filled: [UINode] = []

        public init(
            device: DeviceID,
            firstReadStartedAt: Date? = nil,
            tree: UITree? = nil,
            treeReadAt: Date? = nil,
            screen: UIScreenInfo? = nil,
            lastInputAt: Date? = nil
        ) {
            self.device = device
            self.firstReadStartedAt = firstReadStartedAt
            self.tree = tree
            self.treeReadAt = treeReadAt
            self.screen = screen
            self.lastInputAt = lastInputAt
        }
    }

    public let now: @MainActor @Sendable () -> Date

    public private(set) var activities: [Activity] = []

    public nonisolated init(now: @escaping @MainActor @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// A full read (never a point read); `startedAt` guards against replacing a newer command's record.
    public func recordTreeRead(_ tree: UITree, on device: DeviceID, startedAt: Date) {
        OutputMasks.current.note(tree)
        update(device) { activity in
            activity.firstReadStartedAt = activity.firstReadStartedAt ?? startedAt
            activity.tree = tree
            activity.treeReadAt = now()
            activity.filled = []
        }
    }

    /// A gap fill's result stays in memory: only its password fields' places reach a file, so showing one later still masks it.
    public func recordFill(_ tree: UITree, on device: DeviceID) {
        update(device) { $0.filled = tree.roots.flatMap { $0.flattened() } }
    }

    public func recordScreen(_ screen: UIScreenInfo?, on device: DeviceID) {
        update(device) { $0.screen = screen }
    }

    /// Called when an input event completes, or fails after it may have been sent.
    public func recordInput(on device: DeviceID) {
        update(device) { $0.lastInputAt = now() }
    }

    public func activity(for device: DeviceID) -> Activity? {
        activities.first { $0.device == device }
    }

    public func reset() {
        activities = []
    }

    private func update(_ device: DeviceID, _ change: (inout Activity) -> Void) {
        if let index = activities.firstIndex(where: { $0.device == device }) {
            change(&activities[index])
        } else {
            var activity = Activity(device: device)
            change(&activity)
            activities.append(activity)
        }
    }
}
