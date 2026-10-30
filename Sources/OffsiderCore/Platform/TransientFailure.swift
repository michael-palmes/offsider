/// A failure that can clear by itself within a second or two, such as a screen with no window during an activity change.
public protocol TransientFailure: Error {
    var isTransient: Bool { get }
}

extension Error {
    public var isTransientFailure: Bool {
        (self as? any TransientFailure)?.isTransient == true
    }
}

/// A refusal only because another app is in front: it clears when the app under test comes back, and nothing was read from the other app.
public protocol OtherAppFailure: Error {
    var isOtherAppInFront: Bool { get }
}

extension Error {
    public var isOtherAppInFront: Bool {
        (self as? any OtherAppFailure)?.isOtherAppInFront == true
    }
}
