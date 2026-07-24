# macOS permissions (TCC surface)

The exact TCC permissions TidyTime requests — **Accessibility**, **Automation (Apple Events)**,
**Notifications** — how each is checked and prompted from Swift, why we read window titles through
Accessibility instead of `CGWindowList` (to stay off Screen Recording, guardrail G3), and how the
doctor view / `make doctor` surface live status. **Screen Recording is never requested.**

**Related:** [../README.md](../README.md) (doc index) ·
[chrome-scripting.md](chrome-scripting.md) ·
[../build/signing-and-tcc.md](../build/signing-and-tcc.md) ·
[../guardrails.md](../guardrails.md) (G3, G7) ·
[../../PLAN.md](../../PLAN.md) §10

**Status:** build-ready · **Surface:** `kTCCServiceAccessibility`, `kTCCServiceAppleEvents`,
notification authorization (`UNUserNotificationCenter`) · **Auth:** per-service TCC grants, keyed to
the app's **code signature** (G7) ·
**Source:** Apple docs — `AXIsProcessTrusted`, `AXUIElement` (ApplicationServices/Accessibility);
`AEDeterminePermissionToAutomateTarget` (Apple Events); `UNUserNotificationCenter`; Hardened Runtime
entitlement `com.apple.security.automation.apple-events`; `man tccutil` ·
**Last verified:** 2026-07-23

> ⚠️ **Build-time check:** TCC internals (live-refresh vs. relaunch-to-refresh of
> `AXIsProcessTrusted`, exact System Settings pane deep-links) shift between macOS releases. Verify
> the behaviors flagged below on the actual build target (macOS 14 floor; the on-device model rung
> needs macOS 26). No paid Apple Developer account is used — see
> [../build/signing-and-tcc.md](../build/signing-and-tcc.md).

---

## 0. The whole permission surface at a glance

| # | Capability | TCC service | Requested? | Used by | Info.plist / entitlement |
|---|---|---|---|---|---|
| 1 | Window titles | `kTCCServiceAccessibility` | **Yes** | app/window watcher | (none — pure user grant) |
| 2 | Read Chrome / System Events via Apple Events | `kTCCServiceAppleEvents` | **Yes** (per target app) | Chrome adapter, meeting state | `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events` |
| 3 | Notifications | notification authorization (not tccutil-keyed) | **Yes** | nudges, away prompt | (none) |
| — | Apple Intelligence (on-device model) | not TCC — a System Settings feature toggle | optional | ladder rung 3 | — |
| — | **Screen Recording** | `kTCCServiceScreenCapture` | **NEVER** | — | — |

The app is **not** App-Sandboxed (Accessibility + sending Apple Events to arbitrary apps are
incompatible with the sandbox) but **is** built with the **Hardened Runtime** and a **stable code
signature** (G7). One process, no helpers/daemons (G8).

---

## 1. Accessibility — window titles (and why not `CGWindowList`)

**Service:** `kTCCServiceAccessibility`. **Grant location:** System Settings → Privacy & Security →
Accessibility. No Info.plist usage string exists for Accessibility — it is a pure user grant.

**Why Accessibility and not `CGWindowList` (guardrail G3, [../guardrails.md](../guardrails.md)).**
`CGWindowListCopyWindowInfo`'s `kCGWindowName` field (the window *title*) is gated behind the
**Screen Recording** permission (`kTCCServiceScreenCapture`) on modern macOS. Reading the focused
window's title through the **Accessibility** API (`AXUIElement`) gets the same string **without**
dragging in Screen Recording. Requesting Screen Recording is a design failure, not a shortcut — the
capture sources contain **no** `CGWindowList*` name-reading call, and a guardrail grep test enforces
it ([../architecture/module-map.md](../architecture/module-map.md), `TidyCapture`).

**Check / prompt from Swift:**

```swift
import ApplicationServices

// Non-prompting status check (safe to poll for the doctor view).
func accessibilityIsTrusted() -> Bool { AXIsProcessTrusted() }

// One-time prompt: shows the "open System Settings" dialog if not yet trusted.
func promptForAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)   // returns current trust; side effect is the prompt
}
```

**Read the focused window's title** (frontmost app from `NSWorkspace`, then walk the AX tree):

```swift
import AppKit
import ApplicationServices

func focusedWindowTitle() -> String? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let appEl = AXUIElementCreateApplication(pid)

    var winRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
        let window = winRef, CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }

    var titleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success
    else { return nil }
    return titleRef as? String
}
```

Feeds `activity_samples.window_title` ([../architecture/data-model.md](../architecture/data-model.md)).
The watcher subscribes to `NSWorkspace.didActivateApplicationNotification` for app switches and adds
a 30 s heartbeat ([../../PLAN.md](../../PLAN.md) §4).

**Gotchas:**
- `AXUIElementCopyAttributeValue` returns `.apiDisabledError` (`kAXErrorAPIDisabled`) when the
  process is **not** trusted — treat that as "Accessibility not granted," not a bug.
- ⚠️ **Build-time check:** whether `AXIsProcessTrusted()` flips to `true` **live** after the user
  toggles the grant, or only after an app **relaunch**, has varied by macOS version. Design the
  doctor view to re-poll and instruct a relaunch if a freshly granted permission still reads
  `false`. Do **not** cache the first value for the process lifetime.
- Some apps expose no `kAXFocusedWindowAttribute` (menu-bar-only, full-screen games) — return `nil`
  and let the sample carry app name only.

---

## 2. Automation (Apple Events) — reading Chrome & System Events

**Service:** `kTCCServiceAppleEvents`. TCC keys this **per (client app → target app) pair**, so each
target prompts **separately** on first use: Google Chrome (URL/title/page text — see
[chrome-scripting.md](chrome-scripting.md)) and, if used for meeting-state inference, System Events.
**Grant location:** System Settings → Privacy & Security → Automation (shown as "TidyTime → Google
Chrome," etc.).

**Two hard requirements under the Hardened Runtime** (both already wired into the app shell):

1. **Purpose string** — `NSAppleEventsUsageDescription` in `App/Info.plist`. Without it, sending any
   Apple Event fails (and historically crashes) under macOS 10.14+.
   ```xml
   <key>NSAppleEventsUsageDescription</key>
   <string>TidyTime reads the active tab's URL, title, and visible text from your browser to
   attribute your time. It never controls the browser or changes anything.</string>
   ```
2. **Entitlement** — `com.apple.security.automation.apple-events` = `true` in the app's
   entitlements. The Hardened Runtime blocks **all** outgoing Apple Events without it, before TCC is
   even consulted.
   ```xml
   <!-- App/TidyTime.entitlements -->
   <key>com.apple.security.automation.apple-events</key>
   <true/>
   ```

**First-use prompt.** The TCC prompt fires automatically the first time TidyTime sends an Apple Event
to a given target. Denial returns `errAEEventNotPermitted` (`-1743`) on every subsequent event until
reset. To **pre-check or trigger** the prompt without sending a real command (ideal for the doctor
view and the setup walkthrough), use `AEDeterminePermissionToAutomateTarget`:

```swift
import CoreServices

/// noErr(0)=granted · -1743 denied · -1744 not-yet-decided (when askUser=false) · -600 not running.
func automationStatus(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    return AEDeterminePermissionToAutomateTarget(
        target.aeDesc, typeWildCard, typeWildCard, askUserIfNeeded)
}

// Doctor (silent probe): automationStatus(bundleID: "com.google.Chrome", askUserIfNeeded: false)
// Setup  (may prompt):   automationStatus(bundleID: "com.google.Chrome", askUserIfNeeded: true)
```

Relevant OSStatus values (`CarbonCore`):

| Code | Symbol | Meaning | TidyTime handling |
|---|---|---|---|
| `0` | `noErr` | Automation granted | proceed |
| `-1743` | `errAEEventNotPermitted` | user denied | doctor flags it; walkthrough → System Settings |
| `-1744` | `errAEEventWouldRequireUserConsent` | not decided, `askUser=false` | prompt during setup |
| `-600` | `procNotFound` | target app not running | no-op; retry when it's frontmost |

**Note:** the Automation grant covers **any** Apple Event to Chrome, including URL/title. Chrome's
`execute … javascript` needs an **additional** Chrome-side toggle that is **not** a TCC permission —
that is Chrome's "Allow JavaScript from Apple Events" ([chrome-scripting.md](chrome-scripting.md) §3).

---

## 3. Notifications — nudges & away prompt

Notification authorization is managed by `UNUserNotificationCenter`, **not** by TCC/`tccutil` (it
lives under System Settings → Notifications, not Privacy & Security). Requested lazily the first time
a nudge or away prompt would fire ([../../PLAN.md](../../PLAN.md) §9).

```swift
import UserNotifications

func requestNotifications() async -> Bool {
    (try? await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .sound])) ?? false
}

// Doctor status (no prompt):
func notificationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    // .authorized / .denied / .notDetermined / .provisional
}
```

Nudges are meeting-aware and rate-limited in the Surface layer; denial simply means everything a
nudge would have said still waits in the recap — no capability is lost
([../../PLAN.md](../../PLAN.md) §9). ⚠️ **Build-time check:** requesting notification authorization
from a `MenuBarExtra`/`LSUIElement`-style agent app can behave differently than a windowed app;
confirm the prompt appears on the target macOS.

---

## 4. Screen Recording — never requested (explicit)

TidyTime **never** requests Screen Recording (`kTCCServiceScreenCapture`). It captures **no** screen
pixels and reads **no** window bitmaps. Window titles come solely from Accessibility (§1). This is
guardrail **G3** ([../guardrails.md](../guardrails.md)) and is enforced by a grep-based guardrail
test over `TidyCapture` that fails on any `CGWindowList*` window-name usage. If a future feature
seems to "need" Screen Recording, that is a design failure to escalate — not a permission to add.

---

## 5. TCC grants are keyed to the code signature (G7)

macOS binds every TCC grant to the app's **code signature** (its designated requirement, derived
from the signing identity + bundle id). If the signature changes — an **ad-hoc** signature that
rotates on every rebuild, or a switch to a different certificate — macOS treats it as a **different
app** and **silently revokes** Accessibility and Automation grants. This is the single most common
way this class of app "mysteriously stops working."

**Mitigation (guardrail G7):** ship a **stable identity** and a **fixed bundle id**
(`com.4site.TidyTime`, configurable). Full procedure — free Apple ID personal team or a stable
self-signed cert, committed signing base + gitignored `Local.xcconfig` — in
[../build/signing-and-tcc.md](../build/signing-and-tcc.md). The doctor view (§6) exists precisely so
a dropped grant is **visible**, not silent.

---

## 6. Doctor view & `make doctor` — live status

Both the in-app **doctor** debug view and the `make doctor` command surface the same live permission
state so a dropped or missing grant is obvious ([../../PLAN.md](../../PLAN.md) §11 Phase 0 accept;
glossary "Doctor"). The doctor reads status **without** forcing prompts (all probes below are
non-prompting).

```swift
struct PermissionStatus: Sendable {
    enum State: String, Sendable { case ok, denied, notDetermined, notRunning, unknown }
    let accessibility: State        // AXIsProcessTrusted()
    let automationChrome: State     // AEDeterminePermissionToAutomateTarget(chrome, askUser:false)
    let automationSystemEvents: State
    let notifications: State        // UNUserNotificationCenter authorizationStatus
    let chromeJavaScript: State     // Chrome "Allow JavaScript from Apple Events" probe (chrome-scripting §6)
    let screenRecording = "not requested (by design — G3)"
}
```

| Row | Probe (no prompt) | `ok` when |
|---|---|---|
| Accessibility | `AXIsProcessTrusted()` | returns `true` |
| Automation → Chrome | `AEDeterminePermissionToAutomateTarget(..., false)` | `noErr` (`0`) |
| Automation → System Events | same, System Events bundle id | `noErr` |
| Notifications | `notificationSettings().authorizationStatus` | `.authorized` / `.provisional` |
| Chrome JS toggle | benign `execute javascript "1"` ([chrome-scripting.md](chrome-scripting.md) §6) | returns `"1"` |
| Screen Recording | — | always "not requested" |

The doctor view also prints the DB path (`~/Library/Application Support/TidyTime/tidytime.sqlite`)
and the config path, and offers "Open Settings" deep-links to the relevant Privacy & Security panes
plus the Chrome toggle walkthrough. `make doctor` prints the same table to stdout for terminal-driven
verification (the Claude Code workflow).

---

## 7. `tccutil reset` — resetting grants for test iteration

During development, re-testing the first-run prompt flow means clearing prior grants. `tccutil` does
this per service, scoped to the bundle id:

```bash
# Reset a single service for TidyTime (macOS 11+ supports the bundle-id argument).
tccutil reset Accessibility com.4site.TidyTime
tccutil reset AppleEvents   com.4site.TidyTime   # Automation grants (all target pairs)

# Reset every service TidyTime has touched:
tccutil reset All com.4site.TidyTime
```

**Gotchas:**
- The **service name** for Automation is `AppleEvents` (matches `kTCCServiceAppleEvents`), not
  "Automation." `Accessibility` matches `kTCCServiceAccessibility`.
- Omitting the bundle id resets that service for **every** app on the machine — always pass
  `com.4site.TidyTime`.
- `tccutil` does **not** manage Notifications — reset those via System Settings → Notifications
  (or by reinstalling), since notification auth is not a TCC service (§3).
- After a reset, relaunch the app to re-trigger the first-use prompts; combine with §5 (a signature
  change *also* drops grants — don't confuse the two while debugging).
- ⚠️ **Build-time check:** SIP restricts modifying some TCC entries; resetting your **own** app's
  grants works, but confirm on the target macOS if a reset appears to no-op.

---

## 8. Setup order & acceptance (Phase 0 → Phase 1)

The one-time human setup checklist lives in [../permissions-setup.md](../permissions-setup.md) and
mirrors [../../PLAN.md](../../PLAN.md) §10. TCC-relevant order:

1. **Accessibility** — prompt on first run (§1); grant, relaunch if status still reads `false`.
2. **Automation → Chrome** (and System Events, if meeting-state uses it) — prompt on first Apple
   Event (§2).
3. **Chrome "Allow JavaScript from Apple Events"** — one-time toggle, app-guided
   ([chrome-scripting.md](chrome-scripting.md) §3). Not a TCC permission.
4. **Notifications** — prompt when the first nudge/away prompt would fire (§3).

**Acceptance:**
- `make doctor` and the in-app doctor view show Accessibility = `ok`, Automation → Chrome = `ok`,
  Notifications = `authorized`, Chrome JS = `ok`, and Screen Recording = "not requested."
- Toggling a grant off in System Settings flips the corresponding doctor row to `denied`/`false`
  **without** the app crashing (silent degrade, not a hard failure) — proving the status is *visible*
  (G7 intent).
- No `CGWindowList*` window-name call and no `kTCCServiceScreenCapture` request exist in the build
  (G3 guardrail test green — [../guardrails.md](../guardrails.md)).
