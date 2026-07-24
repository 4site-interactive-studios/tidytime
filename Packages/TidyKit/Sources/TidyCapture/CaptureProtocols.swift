import Foundation

/// Reads the active browser tab + visible page text. Chrome is the only v1 implementation
/// (`ChromeAdapter`); Safari/Firefox/Dia land later without touching the pipeline. Tests use
/// `FakeBrowserAdapter`.
public protocol BrowserAdapter: Sendable {
    var browserName: String { get }
    /// The bundle identifier this adapter drives (e.g. "com.google.Chrome").
    var appBundleId: String { get }
    func activeTab() -> BrowserTab?
    func visiblePageText() -> String?
    /// Whether "Allow JavaScript from Apple Events" is on (page-text capture needs it).
    func javaScriptFromAppleEventsEnabled() -> Bool
}

/// Seconds since the last user input, for idle/away detection.
public protocol IdleReading: Sendable {
    func idleSeconds() -> TimeInterval
}

/// The current frontmost app/window, read on demand (live: NSWorkspace + Accessibility).
public protocol FrontmostReading: Sendable {
    func current() -> FrontmostContext?
}

// MARK: - Fakes for tests

public final class FakeBrowserAdapter: BrowserAdapter, @unchecked Sendable {
    public var browserName: String
    public var appBundleId: String
    public var tab: BrowserTab?
    public var pageText: String?
    public var jsEnabled: Bool
    public init(browserName: String = "chrome", appBundleId: String = "com.google.Chrome",
                tab: BrowserTab? = nil, pageText: String? = nil, jsEnabled: Bool = true) {
        self.browserName = browserName; self.appBundleId = appBundleId
        self.tab = tab; self.pageText = pageText; self.jsEnabled = jsEnabled
    }
    public func activeTab() -> BrowserTab? { tab }
    public func visiblePageText() -> String? { jsEnabled ? pageText : nil }
    public func javaScriptFromAppleEventsEnabled() -> Bool { jsEnabled }
}

public struct FakeIdleReader: IdleReading {
    public var seconds: TimeInterval
    public init(seconds: TimeInterval) { self.seconds = seconds }
    public func idleSeconds() -> TimeInterval { seconds }
}

public struct FakeFrontmost: FrontmostReading {
    public var value: FrontmostContext?
    public init(_ value: FrontmostContext?) { self.value = value }
    public func current() -> FrontmostContext? { value }
}

/// Reference-type frontmost fake whose value can change between polls (for CaptureCoordinator tests).
public final class MutableFrontmostReader: FrontmostReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _value: FrontmostContext?
    public init(_ value: FrontmostContext? = nil) { _value = value }
    public var value: FrontmostContext? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    public func current() -> FrontmostContext? { value }
}
