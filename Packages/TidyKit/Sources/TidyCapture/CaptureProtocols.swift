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
    /// Counts `visiblePageText()` calls so tests can assert the expensive AppleScript round-trip
    /// isn't re-fired on churn (round-2 finding R3-6).
    public private(set) var pageTextCalls = 0
    public func activeTab() -> BrowserTab? { tab }
    public func visiblePageText() -> String? {
        pageTextCalls += 1
        return jsEnabled ? pageText : nil
    }
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


/// Classifies the result of Chrome's `execute … javascript "1"` probe into the row the Doctor view
/// shows.
///
/// Why this exists: `page_snapshots` sat at **0 rows for the life of the database** (proved by the
/// absence of a `sqlite_sequence` row — SQLite creates one on the first successful insert and never
/// removes it) while 34,586 Chrome URLs were captured. That split is the signature of Chrome's
/// "Allow JavaScript from Apple Events" toggle being off: the URL/title path uses plain scripting
/// terms and needs only Automation, while page text needs `execute javascript`, which the toggle
/// gates.
///
/// The environment was the cause, but the *defect* was that nothing said so. Phase 1's acceptance
/// criteria require "…`page_snapshots` gains no rows, **and `doctor` reports the degraded state**",
/// and `permissions-setup.md` tells the user to verify with `make doctor` → Chrome JS = `ok` — a
/// row that did not exist. A documented verification step the user could not perform.
public enum ChromeJavaScriptProbe {
    public static let statusKey = "Chrome JavaScript (Apple Events)"

    public static let ok = "ok"
    public static let toggleOff = "off — Chrome’s “Allow JavaScript from Apple Events” is unchecked"
    public static let automationDenied = "blocked — Automation permission for Chrome is denied"
    public static let notDetermined = "not determined — macOS has not asked yet"
    public static let notRunning = "Chrome not running"
    public static let unknown = "unknown"

    /// Map a raw AppleScript outcome to a status string. `errorNumber`/`errorMessage` are the
    /// `NSAppleScript` error fields; `result` is the script's return value when it succeeded.
    ///
    /// The numbers are AppleScript/Apple Event standards: −1743 "not authorized to send Apple
    /// events", −1744 "user consent required", −600 "application isn't running".
    public static func classify(result: String?, errorNumber: Int?, errorMessage: String?) -> String {
        if let errorNumber {
            switch errorNumber {
            case -1743: return automationDenied
            case -1744: return notDetermined
            case -600, -609: return notRunning
            default: break
            }
        }
        // Chrome's refusal is a plain-language message, not a distinct error number, so the text is
        // the only signal available.
        if let errorMessage, errorMessage.lowercased().contains("turned off") { return toggleOff }
        if errorNumber != nil { return unknown }
        guard let result else { return unknown }
        // The no-windows case returns "1" by construction so an idle Chrome is not misreported.
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? ok : unknown
    }

    /// True only for the status that permits page-text capture.
    public static func isEnabled(_ status: String) -> Bool { status == ok }
}
