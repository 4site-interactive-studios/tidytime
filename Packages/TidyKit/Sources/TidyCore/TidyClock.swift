import Foundation

/// Injectable time source so time-dependent logic (sessionization, rounding, retention, nudges)
/// is deterministic in tests. Named `TidyClock` to avoid colliding with Swift's `Clock` protocol.
public protocol TidyClock: Sendable {
    var now: Date { get }
}

/// Production clock.
public struct SystemClock: TidyClock {
    public init() {}
    public var now: Date { Date() }
}

/// Test clock with a fixed, advanceable instant.
public final class FixedClock: TidyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    public init(_ now: Date) { self._now = now }
    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
    /// Advance the clock by `seconds`.
    public func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        _now = date
    }
}
