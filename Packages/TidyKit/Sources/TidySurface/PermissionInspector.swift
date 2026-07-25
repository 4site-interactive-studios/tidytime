import Foundation
import TidyCore

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
            "Automation (Chrome)": Self.automationStatus(bundleId: KnownBundle.chrome),
            "Automation (System Events)": Self.automationStatus(bundleId: KnownBundle.systemEvents),
            "Notifications": Self.notificationStatus(),
            "Screen Recording": "not requested (by design — G3)",
        ]
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

    static func notificationStatus() -> String {
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
