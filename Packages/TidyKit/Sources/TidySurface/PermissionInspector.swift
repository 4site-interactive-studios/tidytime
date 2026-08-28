import Foundation
import TidyCore
import TidyCapture

#if canImport(AppKit)
import AppKit
import ApplicationServices
import UserNotifications

/// Live TCC/permission status for the `doctor` view and the diagnostic bundle.
///
/// Deliberately **read-only**: `AXIsProcessTrusted()` checks without prompting, and Automation is
/// probed via `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`. Prompting is a
/// separate, explicit user action (`requestAccessibility` / `requestNotifications`) so opening the
/// doctor view never triggers a system dialog.
///
/// Screen Recording is **never** inspected or requested (guardrail G3).
public struct PermissionInspector: PermissionStatusProviding {
    public init() {}

    public func statuses() -> [String: String] {
        [
            "Accessibility": AXIsProcessTrusted() ? "granted" : "not granted",
            "Code signature": Self.signatureStatus(),
            "Automation (Chrome)": Self.automationStatus(bundleId: KnownBundle.chrome),
            "Automation (System Events)": Self.automationStatus(bundleId: KnownBundle.systemEvents),
            "Notifications": Self.notificationStatus(),
            ChromeJavaScriptProbe.statusKey: Self.chromeJavaScriptStatus(),
            "Screen Recording": "not requested (by design — G3)",
        ]
    }

    private static let chromeJSCache = NotificationStatusCache()

    /// Chrome's "Allow JavaScript from Apple Events" toggle — a Chrome setting, not a TCC grant.
    ///
    /// Without this row the toggle being off is completely invisible: page-text capture returns nil
    /// silently, `page_snapshots` stays at 0 forever, and every other signal looks healthy because
    /// URL/title capture does not need the toggle. `permissions-setup.md` has always told the user
    /// to verify with `make doctor` → Chrome JS = `ok`; this is the row it was promising.
    ///
    /// Cached like `notificationStatus`: Doctor refreshes every 3s and a synchronous AppleScript
    /// round-trip on the main thread must not run at that rate.
    static func chromeJavaScriptStatus() -> String {
        chromeJSCache.value(ttl: 15) { ChromeAdapter.javaScriptProbeStatus() }
    }

    /// The single most useful line in this view when permissions "won't stick".
    ///
    /// macOS records a TCC grant against the app's **code-signing identity**. An ad-hoc/linker-signed
    /// build has no stable identity, so System Settings can show the toggle ON while
    /// `AXIsProcessTrusted()` still returns false — the grant was recorded for a build that, as far
    /// as macOS is concerned, is not this one. That is guardrail **G7**, and it is invisible unless
    /// something says so out loud.
    static func signatureStatus() -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return "unknown" }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return "unknown" }

        let flags = (info["flags"] as? UInt32) ?? 0
        let isAdhoc = (flags & 0x2) != 0                      // kSecCodeSignatureAdhoc
        let team = info["teamid"] as? String
        let identifier = (info["identifier"] as? String) ?? "?"

        if isAdhoc || team == nil {
            return "⚠️ AD-HOC (id: \(identifier)) — TCC grants will NOT persist; set DEVELOPMENT_TEAM"
        }
        return "stable (team \(team!), id: \(identifier))"
    }

    enum KnownBundle {
        static let chrome = "com.google.Chrome"
        static let systemEvents = "com.apple.systemevents"
    }

    /// Non-prompting Apple Events probe.
    static func automationStatus(bundleId: String) -> String {
        var target = AEAddressDesc()
        let data = Array(bundleId.utf8)
        let created = data.withUnsafeBufferPointer { buf in
            AECreateDesc(typeApplicationBundleID, buf.baseAddress, buf.count, &target)
        }
        guard created == noErr else { return "unknown" }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return "granted"
        case OSStatus(errAEEventNotPermitted): return "denied"
        case OSStatus(procNotFound): return "app not running"
        case -1744: return "not determined"   // errAEEventWouldRequireUserConsent
        default: return "unknown (\(status))"
        }
    }

    /// Cached because the underlying query blocks its caller (semaphore, up to 2s) and Doctor's
    /// reload timer calls statuses() on the MAIN thread every 3s — an unlucky slow reply would
    /// visibly hitch the UI (round-3 R1-C6). 15s TTL keeps Doctor honest enough while making the
    /// steady-state cost zero.
    private static let notificationCache = NotificationStatusCache()

    static func notificationStatus() -> String {
        // `UNUserNotificationCenter.current()` raises an uncatchable ObjC exception
        // ("bundleProxyForCurrentProcess is nil") when the process has no app bundle — a test
        // runner, or a command-line tool like `tidytime-doctor`. Check first: an inspector that
        // hard-crashes outside an app bundle cannot be used by the tooling that most needs it.
        // The check is on the bundle SHAPE, not its identifier: a test runner reports an
        // identifier but its bundleURL is a plain directory
        // (…/Xcode.app/Contents/Developer/usr/bin/), which is exactly the case that raises.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return "unknown (no app bundle)" }
        return notificationCache.value(ttl: 15) {
            let sem = DispatchSemaphore(value: 0)
            var result = "unknown"
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized: result = "granted"
                case .denied: result = "denied"
                case .notDetermined: result = "not determined"
                case .provisional: result = "provisional"
                case .ephemeral: result = "ephemeral"
                @unknown default: result = "unknown"
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2)
            return result
        }
    }

    // MARK: Explicit prompts (user-initiated only)

    /// Opens the system prompt for Accessibility. Call from a button, never on launch.
    public static func requestAccessibility() {
        // The constant is a global `var` (not concurrency-safe to reference); its value is the
        // documented literal key, so use that directly.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Open the relevant System Settings pane so the user can grant a denied permission.
    public static func openSettings(pane: String = "Privacy_Accessibility") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
#else
public struct PermissionInspector: PermissionStatusProviding {
    public init() {}
    public func statuses() -> [String: String] { [:] }
}
#endif

/// Small TTL cache for the blocking notification-status probe.
final class NotificationStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (value: String, at: Date)?

    func value(ttl: TimeInterval, compute: () -> String) -> String {
        lock.lock()
        if let cached, Date().timeIntervalSince(cached.at) < ttl {
            let v = cached.value
            lock.unlock()
            return v
        }
        lock.unlock()
        let fresh = compute()
        lock.lock()
        cached = (fresh, Date())
        lock.unlock()
        return fresh
    }
}
