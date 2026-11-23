import Darwin

/// Typed secret bytes in one fixed allocation that never grows or moves. Every byte it frees is zeroed first.
@safe public final class SecretBytes {
    public let capacity: Int
    public private(set) var count = 0
    private let storage: UnsafeMutableBufferPointer<UInt8>

    enum AuditEvent: Equatable {
        case made(capacity: Int)
        /// The whole allocation, read after zeroing and just before it is freed.
        case released([UInt8])
    }

    /// Test hook for every buffer made and freed, bound per task so parallel tests never see each other's buffers.
    @TaskLocal static var audit: (@Sendable (AuditEvent) -> Void)?

    public init(capacity: Int) {
        self.capacity = max(capacity, 0)
        unsafe storage = .allocate(capacity: self.capacity)
        unsafe storage.initialize(repeating: 0)
        Self.audit?(.made(capacity: self.capacity))
    }

    deinit {
        unsafe Self.zero(storage.baseAddress, storage.count)
        unsafe Self.audit?(.released(Array(storage)))
        unsafe storage.deallocate()
    }

    public var isEmpty: Bool { count == 0 }

    /// The bytes held, readable only inside `body`.
    public func withBytes<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        try unsafe body(UnsafeBufferPointer(rebasing: storage[..<count]))
    }

    /// Lets `fill` write into the free space and keeps what it says it wrote. A negative result keeps nothing.
    @discardableResult
    public func append(reading fill: (UnsafeMutableRawBufferPointer) -> Int) -> Int {
        let free = unsafe UnsafeMutableRawBufferPointer(UnsafeMutableBufferPointer(rebasing: storage[count...]))
        let written = unsafe min(max(fill(free), 0), free.count)
        count += written
        return written
    }

    /// Inserts as much of `bytes` at `index` as fits, and returns how many went in.
    @discardableResult
    public func insert(_ bytes: some Collection<UInt8>, at index: Int) -> Int {
        let index = min(max(index, 0), count)
        let fitting = min(bytes.count, capacity - count)
        guard fitting > 0, let base = unsafe storage.baseAddress else { return 0 }
        unsafe memmove(base + index + fitting, base + index, count - index)
        for (offset, byte) in bytes.prefix(fitting).enumerated() { unsafe base[index + offset] = byte }
        count += fitting
        return fitting
    }

    /// Removes `range`, zeroing the bytes it frees at the end.
    public func remove(_ range: Range<Int>) {
        let range = range.clamped(to: 0..<count)
        guard !range.isEmpty, let base = unsafe storage.baseAddress else { return }
        unsafe memmove(base + range.lowerBound, base + range.upperBound, count - range.upperBound)
        count -= range.count
        unsafe Self.zero(base + count, range.count)
    }

    public func removeAll() {
        remove(0..<count)
    }

    private static func zero(_ base: UnsafeMutablePointer<UInt8>?, _ length: Int) {
        guard let base = unsafe base, length > 0 else { return }
        _ = unsafe memset_s(base, length, 0, length)
    }
}
