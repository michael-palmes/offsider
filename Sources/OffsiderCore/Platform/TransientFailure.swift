/// A failure that can clear by itself within a second or two, such as a screen with no window during an activity change.
public protocol TransientFailure: Error {
    var isTransient: Bool { get }
}

extension Error {
    public var isTransientFailure: Bool {
        (self as? any TransientFailure)?.isTransient == true
    }
}
