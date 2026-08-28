import Foundation
import TidyCore
import TidyCapture

/// Plain-language troubleshooting for every non-green Doctor row.
///
/// All logic here is PURE and keyed to the **exact** status strings `PermissionInspector` emits, so
/// it is fully testable headlessly — `DoctorView` only renders the results. The step content encodes
/// the failure modes learned from real first-run support this session: stale TCC rows from older
/// build variants, grants that need a relaunch, the ad-hoc-signature trap, benign "app not running"
/// probes, and rate-limit waits.

// MARK: - Severity

/// How a status string should read at a glance. Replaces the old `color(for:)`, which rendered the
/// perfectly healthy `stable (team …)` code signature ORANGE (prefix-matching only "granted").
public enum StatusSeverity: Equatable, Sendable {
    case healthy      // green
    case broken       // red
    case neutral      // secondary — benign, by design, or unknowable right now
    case attention    // orange — needs the user to do something

    public static func classify(_ status: String) -> StatusSeverity {
        if status.hasPrefix("granted") || status.hasPrefix("stable (") { return .healthy }
        if status.hasPrefix("denied") { return .broken }
        // "app not running": the Apple Events probe returns procNotFound until the target app is
        // open — nothing is wrong. "provisional": notifications will be delivered quietly.
        if status.contains("not requested") || status == "app not running" || status == "provisional" {
            return .neutral
        }
        return .attention
    }
}

// MARK: - Tips

public struct TroubleshootingTip: Equatable, Sendable {
    /// Ordered, plain-language steps. The view numbers them.
    public let steps: [String]
    /// When set, the view offers an "Open System Settings" button to this pane.
    public let settingsPane: String?
    /// True only for the google needs-sign-in tip — the view renders the Sign in button.
    public let offersGoogleSignIn: Bool

    public init(steps: [String], settingsPane: String? = nil, offersGoogleSignIn: Bool = false) {
        self.steps = steps
        self.settingsPane = settingsPane
        self.offersGoogleSignIn = offersGoogleSignIn
    }
}

public enum DoctorTips {
    // MARK: Permissions

    /// A tip for a permission row, or nil when the status is healthy/neutral enough to need none.
    public static func tip(forPermission name: String, status: String) -> TroubleshootingTip? {
        switch StatusSeverity.classify(status) {
        case .healthy: return nil
        case .neutral where status.contains("not requested"): return nil   // by design (G3)
        default: break
        }

        switch name {
        case "Accessibility":
            return TroubleshootingTip(steps: [
                "Click “Request Accessibility” below.",
                "In the System Settings window that opens, find TidyTime in the list and turn it on.",
                "Quit TidyTime and open it again — macOS often only honors this permission after a relaunch.",
                "Still says “not granted”? The list may contain a leftover row from an older copy of TidyTime. Select TidyTime in System Settings and remove it with the − (minus) button — just switching it off is not enough — then relaunch TidyTime and grant it again.",
                "If the permission keeps disappearing every time the app updates, check the “Code signature” row above — an unstable signature makes macOS forget grants.",
            ], settingsPane: "Privacy_Accessibility")

        case ChromeJavaScriptProbe.statusKey:
            if status == ChromeJavaScriptProbe.ok { return nil }
            if status == ChromeJavaScriptProbe.notRunning {
                return TroubleshootingTip(steps: [
                    "This is normal — TidyTime can’t check this while Chrome is closed.",
                    "Open Chrome and this row will update by itself within a few seconds.",
                ])
            }
            if status == ChromeJavaScriptProbe.automationDenied || status == ChromeJavaScriptProbe.notDetermined {
                return TroubleshootingTip(steps: [
                    "Fix the “Automation (Chrome)” row above first — this check can’t run until TidyTime is allowed to talk to Chrome.",
                    "Once that says granted, come back to this row.",
                ], settingsPane: "Privacy_Automation")
            }
            return TroubleshootingTip(steps: [
                "In Google Chrome, open the menu bar → View → Developer.",
                "Click “Allow JavaScript from Apple Events” so it shows a checkmark. (The Developer submenu is near the bottom of the View menu.)",
                "No restart needed — TidyTime picks it up on the next capture, within about 20 seconds.",
                "This is a Chrome setting, not a macOS permission, so it will not appear in System Settings.",
                "Until it is on, TidyTime still records which pages you visited (URL and title) — it just can’t read the page text, so the “page snapshots” count stays at zero.",
            ])

        case "Automation (Chrome)", "Automation (System Events)":
            let target = name.contains("Chrome") ? "Google Chrome" : "System Events"
            if status == "app not running" {
                return TroubleshootingTip(steps: [
                    "This is normal — macOS can’t check this permission until \(target) is open.",
                    "Open \(target) and this row will update by itself within a few seconds.",
                ])
            }
            if status == "not determined" {
                return TroubleshootingTip(steps: [
                    "macOS hasn’t asked you yet.",
                    "Use \(target) for a moment while TidyTime is running — a prompt saying TidyTime “wants access to control \(target)” will appear.",
                    "Click OK on that prompt.",
                ])
            }
            return TroubleshootingTip(steps: [
                "Open System Settings → Privacy & Security → Automation.",
                "Expand TidyTime in the list and turn on \(target).",
                "If TidyTime isn’t listed there yet, use \(target) for a moment with TidyTime running so macOS shows the permission prompt.",
            ], settingsPane: "Privacy_Automation")

        case "Notifications":
            if status == "not determined" {
                return TroubleshootingTip(steps: [
                    "Click “Request Notifications” below and choose Allow.",
                ])
            }
            return TroubleshootingTip(steps: [
                "Open System Settings → Notifications, find TidyTime, and turn on “Allow Notifications”.",
                "Nothing is lost in the meantime — anything a notification would have told you waits in the daily recap.",
            ])

        case "Code signature":
            if status.hasPrefix("⚠️ AD-HOC") {
                return TroubleshootingTip(steps: [
                    "This copy of TidyTime has no stable identity, so macOS forgets its permissions every time it’s rebuilt.",
                    "In Terminal, run: bash scripts/find-team-id.sh — it finds your Apple team id and writes it into Local.xcconfig (DEVELOPMENT_TEAM).",
                    "Rebuild the app (make dmg), reinstall it, and grant Accessibility and Automation once more — after that they stick.",
                ])
            }
            return TroubleshootingTip(steps: [
                "TidyTime couldn’t read its own signature — this usually means a debug or preview build.",
                "Build and install the real app (make dmg), then check this row again.",
            ])

        default:
            return TroubleshootingTip(steps: [
                "This is an unexpected status. Click “Copy diagnostic bundle” below and paste it to your AI assistant — it contains everything needed to figure this out, and no secrets.",
            ])
        }
    }

    /// The status text for an ingest row.
    ///
    /// A source can be `.ready` — it *can* run — while its last run failed. Rendering that as the
    /// word "ready" in red was contradictory: the colour said broken, the word said fine, and the
    /// reason sat collapsed behind "How to fix". The failure belongs in the row itself.
    public static func ingestLabel(_ readiness: IngestCoordinator.Readiness,
                                   lastError: String?) -> String {
        guard readiness.canRun, let lastError, !lastError.isEmpty else {
            return readiness.explanation
        }
        return "ready — last sync failed: \(summarize(lastError))"
    }

    /// First clause of an error, trimmed to fit a row. The full text stays in the tip below it.
    static func summarize(_ error: String, limit: Int = 60) -> String {
        let firstLine = error.split(separator: "\n").first.map(String.init) ?? error
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Ingest sources

    /// A tip for an ingest row. `configPath` lets steps name the exact config file on THIS machine.
    /// Returns nil for a ready source with no recorded error.
    public static func tip(for source: IngestCoordinator.Source,
                           readiness: IngestCoordinator.Readiness,
                           lastError: String?,
                           configPath: String) -> TroubleshootingTip? {
        switch readiness {
        case .ready:
            guard let lastError, !lastError.isEmpty else { return nil }
            var steps = ["Last error: \(lastError)"]
            if let hint = hint(forLastError: lastError) { steps.append(hint) }
            steps.append("Errors clear automatically after the next successful sync — every 15 minutes, or press “Sync now” at the bottom of this Sources list. (It is only here in Doctor; the menu bar popover has no sync button.)")
            return TroubleshootingTip(steps: steps)

        case .disabledByKillSwitch:
            return TroubleshootingTip(steps: [
                "This source is switched off in TidyTime’s settings file.",
                "Open \(configPath) in any text editor, find “kill_switches”, and change this source back to true.",
                "Quit and reopen TidyTime.",
            ])

        case .missingConfig(let key) where key.contains("productive_organization_id"):
            return TroubleshootingTip(steps: [
                "TidyTime needs your Productive organization number.",
                "Open Productive in your browser and look at the address bar: the number right after “app.productive.io/” is it (for example app.productive.io/1234-yourcompany → 1234).",
                "Open \(configPath) in any text editor.",
                "Inside “organization”, set “productive_organization_id” to that number, in quotes.",
                "Quit and reopen TidyTime, then press “Sync now” at the bottom of the Sources list in this Doctor window. (It is only here; the menu bar popover has no sync button.)",
            ])

        case .missingConfig(let key) where key.contains("client_id"):
            return TroubleshootingTip(steps: [
                "Google sign-in needs a Client ID first.",
                "Open Settings → Credentials and follow the “Google client secret” instructions — they walk through creating the Google credentials.",
                "Copy the Client ID (it ends in .apps.googleusercontent.com) into \(configPath) under “google” → “client_id”.",
                "Quit and reopen TidyTime.",
            ])

        case .missingConfig(let key):
            return TroubleshootingTip(steps: [
                "A setting named “\(key)” is missing.",
                "Open \(configPath) in a text editor and fill it in, then relaunch TidyTime.",
            ])

        case .missingCredential(let key):
            let name = CredentialCatalogNaming.displayName(for: key)
            return TroubleshootingTip(steps: [
                "TidyTime doesn’t have your \(name) yet.",
                "Open Settings → Credentials — the “\(name)” row there has step-by-step instructions for getting one and pasting it in.",
            ])

        case .needsSignIn:
            return TroubleshootingTip(steps: [
                "Everything is configured — one click left.",
                "Click “Sign in with Google” (also in Settings → Credentials), approve in the browser window that opens, and come back.",
            ], offersGoogleSignIn: true)

        case .notImplemented(let why):
            return TroubleshootingTip(steps: [
                "This source isn’t available yet: \(why).",
            ])
        }
    }

    /// One-line, plain-language reading of a recorded sync error. nil when unrecognized
    /// (the raw error line is still shown).
    public static func hint(forLastError error: String) -> String? {
        let lower = error.lowercased()
        if lower.contains("429") || lower.contains("ratelimit") || lower.contains("rate limit") {
            return "The service is telling TidyTime to slow down — nothing to fix. It retries automatically on the next cycle."
        }
        if lower.contains("invalid_auth") || lower.contains("token_revoked")
            || lower.contains("401") || lower.contains("unauthorized") {
            return "The saved token stopped working. Remove it in Settings → Credentials and paste a fresh one."
        }
        if lower.contains("invalid_grant") || lower.contains("sign in again") {
            return "Google sign-in expired — click Sign in with Google in Settings → Credentials."
        }
        if lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("offline") || lower.contains("network") {
            return "Looks like a network hiccup — it retries automatically. If it persists, check your internet connection."
        }
        return nil
    }
}

/// Human names for keys, delegating to `CredentialCatalog` so tips and the Credentials tab can
/// never drift apart.
public enum CredentialCatalogNaming {
    public static func displayName(for key: String) -> String {
        CredentialCatalog.info(for: key)?.displayName ?? key
    }
}
