# Chrome scripting (AppleScript / Apple Events)

How TidyTime reads the active Chrome tab's **URL + title** (no browser config) and its **visible
page text** (`document.body.innerText`, one-time toggle required), the snapshot/dedupe policy that
fills `page_snapshots`, and the `BrowserAdapter` seam that lets Safari/Firefox/Dia land later.

**Related:** [../README.md](../README.md) (doc index) ·
[macos-permissions-tcc.md](macos-permissions-tcc.md) ·
[../architecture/capture-layer.md](../architecture/capture-layer.md) ·
[../architecture/data-model.md](../architecture/data-model.md) ·
[../../PLAN.md](../../PLAN.md) §4

**Status:** build-ready · **Transport:** AppleScript over Apple Events (no HTTP) ·
**Permission:** Automation → Google Chrome (Apple Events); page text additionally needs Chrome's
"Allow JavaScript from Apple Events" toggle ·
**Source:** Chrome AppleScript dictionary (Script Editor → File → Open Dictionary → Google Chrome);
<https://support.google.com/chrome/?p=applescript>; Apple `NSAppleScript` / Apple Events
Programming Guide ·
**Last verified:** 2026-07-23

> ⚠️ **Build-time check:** Google ships **no** official public reference for Chrome's AppleScript
> dictionary or the JS-from-Apple-Events behavior. Everything below is verified against community
> docs and the on-disk dictionary as of 2026-07-23. Re-open the dictionary in Script Editor on the
> installed Chrome build and confirm the `execute` command and `active tab` terms before relying on
> exact syntax. Match errors by **message substring**, not by numeric code (codes are unstable).

---

## 1. What this module owns

| Concern | Answer |
|---|---|
| Target app | Google Chrome, bundle id `com.google.Chrome` |
| Owning target | `TidyCapture` (impl); protocol in `TidyCore` — see [../architecture/module-map.md](../architecture/module-map.md) |
| Writes | `activity_samples` (url/title, via the watcher) and `page_snapshots` (page text) — [../architecture/data-model.md](../architecture/data-model.md) |
| Two independent permission gates | (a) Automation → Chrome for **any** Apple Event; (b) the "Allow JavaScript from Apple Events" toggle for `execute … javascript` only |
| Phase | 1 (Capture) — see the phase acceptance criteria in [../README.md](../README.md) |

The Chrome adapter is invoked by the app/window watcher **only while Chrome is the frontmost app**
(on a tab switch, a meaningful title/URL change, or the 30-second heartbeat). It never polls Chrome
in the background. One process, event-driven (guardrail G8, [../guardrails.md](../guardrails.md)).

---

## 2. URL + title (no configuration, Automation grant only)

Chrome exposes the active tab's `URL` and `title` directly in its scripting dictionary. Reading them
needs **only** the Automation (Apple Events) grant for Chrome — no developer toggle, no page
scripting. This is the always-available floor: even if page text is off, TidyTime still gets
URL + title.

```applescript
-- Active tab URL + title of the frontmost Chrome window.
-- Returns "" fields when Chrome has no window open.
tell application "Google Chrome"
    if (count of windows) is 0 then return "|"
    set theURL to URL of active tab of front window
    set theTitle to title of active tab of front window
    return theURL & "|" & theTitle
end tell
```

Notes:
- `front window` is the frontmost **browser** window; minimized/other-space windows are skipped by
  Chrome's own ordering. Guard `count of windows` to avoid an error when only a menu/panel is open.
- We serialize the two values with a delimiter (`|` above) so one Apple Event round-trip returns
  both; parse on the Swift side. Pick a delimiter unlikely to appear in a URL, or return an Apple
  Script `list` and read `.atIndex(_:)` from the reply descriptor.
- Incognito windows are still scriptable; if you want to **exclude** incognito, check
  `mode of front window is "incognito"` and skip page-text capture for it (recommended — see §7).

---

## 3. Visible page text (`execute javascript`, needs the one-time toggle)

Visible text comes from running JavaScript in the active tab and reading `document.body.innerText`.
Chrome gates this behind a one-time user toggle:

> **View → Developer → "Allow JavaScript from Apple Events"** (checkmark on).

The Developer submenu only appears when the menu bar's **View** menu is expanded; the app's setup
flow walks the user through enabling it (Phase 1), and TidyTime **detects** whether it is on before
relying on it (§6). When the toggle is off, the command raises an error whose message contains
`turned off` and a link to `support.google.com/chrome/?p=applescript`.

```applescript
-- Visible text of the active tab. Requires "Allow JavaScript from Apple Events".
-- Errors (message contains "turned off") when the toggle is off.
tell application "Google Chrome"
    if (count of windows) is 0 then return ""
    set t to active tab of front window
    -- Guard against pages with no body (chrome://, PDF viewer, blank tabs).
    execute t javascript "document.body ? document.body.innerText : ''"
end tell
```

The `execute … javascript` command returns the evaluated value; for `innerText` that is a plain
string. Keep the injected JS trivial and read-only — no DOM mutation, no navigation. TidyTime never
uses Apple Events to **control** the browser (open tabs, click, submit); it only reads.

---

## 4. Running these from Swift (`ChromeAdapter`)

Compile each script **once** as `NSAppleScript` and reuse it; `executeAndReturnError` dispatches the
Apple Event and returns an `NSAppleEventDescriptor`. `NSAppleScript` is **not** thread-safe and must
run where Apple Event dispatch is available — pin the adapter to the main actor (or a single
dedicated serial executor), and have the capture actor `await` it.

```swift
// Packages/TidyKit/Sources/TidyCapture/Browser/ChromeScripts.swift
enum ChromeScripts {
    static let activeTab = """
    tell application "Google Chrome"
        if (count of windows) is 0 then return "|"
        set theURL to URL of active tab of front window
        set theTitle to title of active tab of front window
        return theURL & "|" & theTitle
    end tell
    """

    static let visibleText = """
    tell application "Google Chrome"
        if (count of windows) is 0 then return ""
        set t to active tab of front window
        execute t javascript "document.body ? document.body.innerText : ''"
    end tell
    """
}
```

```swift
// Packages/TidyKit/Sources/TidyCapture/Browser/ChromeAdapter.swift
@MainActor
final class ChromeAdapter: BrowserAdapter {          // BrowserAdapter defined in TidyCore
    let browserId = "chrome"
    let bundleId  = "com.google.Chrome"

    private let tabScript  = NSAppleScript(source: ChromeScripts.activeTab)!
    private let textScript = NSAppleScript(source: ChromeScripts.visibleText)!

    func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleId }
    }

    func activeTab() throws -> BrowserTab? {
        var err: NSDictionary?
        let out = tabScript.executeAndReturnError(&err)
        if let err { throw mapAppleScriptError(err) }
        guard let joined = out.stringValue, joined != "|" else { return nil }
        let parts = joined.components(separatedBy: "|")
        let url = parts.first ?? ""
        let title = parts.dropFirst().joined(separator: "|")   // titles may contain "|"
        return url.isEmpty ? nil : BrowserTab(url: url, title: title)
    }

    func visiblePageText() throws -> String? {
        var err: NSDictionary?
        let out = textScript.executeAndReturnError(&err)
        if let err { throw mapAppleScriptError(err) }   // e.g. .javaScriptDisabled
        let text = out.stringValue ?? ""
        return text.isEmpty ? nil : text
    }
}
```

```swift
// Map the NSAppleScript error dict to a typed, degrade-able error.
// Detection is by MESSAGE, because Chrome's numeric codes are not contractual.
private func mapAppleScriptError(_ err: NSDictionary) -> BrowserCaptureError {
    let msg  = (err[NSAppleScript.errorMessage] as? String ?? "").lowercased()
    let code = (err[NSAppleScript.errorNumber]  as? Int) ?? 0
    if msg.contains("turned off") || msg.contains("applescript")
        && msg.contains("javascript") { return .javaScriptDisabled }
    switch code {
    case -1743: return .automationDenied   // errAEEventNotPermitted (user said No)
    case -1744: return .automationUndetermined // errAEEventWouldRequireUserConsent
    case -600:  return .notRunning         // procNotFound
    default:    return .scriptFailed(code: code, message: msg)
    }
}
```

> ⚠️ **Build-time check:** the exact `errorNumber` for the JS-disabled case is **not** stable across
> Chrome versions (seen as generic in the wild). The message-substring match on `turned off` is the
> reliable signal; keep the numeric branch only as a fallback.

---

## 5. Capture policy → `page_snapshots`

Snapshot the active tab's text and persist it under the current `activity_samples` row. Columns are
fixed by [../architecture/data-model.md](../architecture/data-model.md): `page_snapshots(sample_id,
captured_at, url, title, content_hash, text, text_bytes)`.

**When to snapshot** (each condition, while Chrome is frontmost):
1. **Tab focus / switch** — the active-tab URL changes.
2. **Meaningful title change on the same URL** — SPA route changes (Gmail, Docs, EN admin) that
   swap `document.title` without a URL change. Debounce ~1.5 s so mid-typing title churn (e.g. a
   Google Doc showing the doc name) doesn't thrash.
3. **Heartbeat backstop** — at most once per active-tab per N seconds even without a change, so a
   long-lived tab whose content mutated still gets a fresh sample.

**How to store:**
1. Read `innerText` via `visiblePageText()`.
2. **Truncate to ~4 KB** — 4096 **UTF-8 bytes**, cut on a Unicode scalar boundary (never split a
   scalar). Store the byte length in `text_bytes`.
3. **`content_hash = sha256(truncatedText)`** (hex). Compute over the *stored* (truncated) text.
4. **Dedupe:** if a recent `page_snapshots` row for the same `url` already has this `content_hash`,
   **skip the insert** (re-focusing an unchanged tab is not new signal). The
   `idx_snapshots_hash` index on `content_hash` makes the lookup cheap.
5. Otherwise insert one row: `sample_id` = current `activity_samples.id`, `captured_at` = now
   (epoch s, UTC), `url`, `title`, `content_hash`, `text`, `text_bytes`.

```swift
// Packages/TidyKit/Sources/TidyCapture/Browser/PageSnapshotCapturer.swift
func snapshot(sampleId: Int64, tab: BrowserTab, adapter: BrowserAdapter,
              store: PageSnapshotDAO) throws {
    guard let raw = try adapter.visiblePageText() else { return } // toggle off / empty → degrade
    let text  = raw.truncatedToUTF8Bytes(4096)                    // scalar-safe truncation
    let hash  = SHA256.hex(of: text)
    guard try !store.hasRecent(url: tab.url, contentHash: hash) else { return } // dedupe
    try store.insert(PageSnapshot(
        sampleId: sampleId, capturedAt: Clock.now(),              // injectable Clock
        url: tab.url, title: tab.title,
        contentHash: hash, text: text, textBytes: text.utf8.count))
}
```

```swift
extension String {
    /// Truncate to at most `maxBytes` UTF-8 bytes without splitting a Unicode scalar.
    func truncatedToUTF8Bytes(_ maxBytes: Int) -> String {
        if utf8.count <= maxBytes { return self }
        var end = unicodeScalars.startIndex
        var used = 0
        for scalar in unicodeScalars {
            let n = String(scalar).utf8.count
            if used + n > maxBytes { break }
            used += n; end = unicodeScalars.index(after: end)
        }
        return String(String.UnicodeScalarView(unicodeScalars[..<end]))
    }
}
```

Retention: `page_snapshots` is a raw, high-volume, sensitive table — it **purges after the retention
window** (default 90 days) and cascade-deletes with its `activity_samples` parent (guardrail G9,
[../guardrails.md](../guardrails.md); [../architecture/data-model.md](../architecture/data-model.md)
§Retention).

---

## 6. Silent degrade (never block, never nag)

Page-text capture is best-effort. On **any** failure — toggle off, Automation denied, no window,
`chrome://`/PDF/blank page, script error, Chrome mid-restart — the adapter throws a typed
`BrowserCaptureError`; the capturer swallows it, records **nothing** in `page_snapshots`, and the
watcher still writes the `activity_samples` row with `is_browser = 1`, `browser = 'chrome'`, and the
`url` (from §2, which uses the weaker permission). URL + title alone still classify most sessions.

- Log the degrade at **debug** through `TidyLog` (never `print`); do **not** raise a per-sample
  alert. Repeated per-tab errors must not spam the log — coalesce.
- Set a **doctor** status flag so the state is *visible* rather than silent
  (see [macos-permissions-tcc.md](macos-permissions-tcc.md) §6): e.g. `chromeJavaScript: .off` when
  a `.javaScriptDisabled` error is seen, `.ok` after a successful text read, `.unknown` before the
  first attempt.

**Toggle detection.** On the first browser capture (and on demand from the doctor view), run a
benign probe — `execute … javascript "1"` — once:

| Result | Interpretation | Action |
|---|---|---|
| returns `"1"` | toggle on, Automation granted | mark `chromeJavaScript: .ok` |
| error msg contains `turned off` | Automation granted, toggle **off** | mark `.off`; show the one-time View → Developer walkthrough |
| error `-1743` | Automation **denied** | mark `.automationDenied`; route to the TCC prompt/walkthrough |
| error `-1744` | Automation not yet decided | trigger the first-use prompt (see TCC doc §3) |
| error `-600` | Chrome not running | no-op; retry when Chrome is frontmost again |

```swift
// TidyCore — the degrade contract the capturer and doctor both read.
public enum BrowserCaptureError: Error, Sendable, Equatable {
    case javaScriptDisabled          // Chrome toggle off — degrade to URL+title
    case automationDenied            // errAEEventNotPermitted (-1743)
    case automationUndetermined      // errAEEventWouldRequireUserConsent (-1744)
    case notRunning                  // procNotFound (-600)
    case scriptFailed(code: Int, message: String)
}
```

---

## 7. The `BrowserAdapter` seam (Chrome-only v1)

All browser access is behind one protocol so the capture pipeline never mentions Chrome directly and
future browsers drop in without touching sessionization or storage
([../architecture/module-map.md](../architecture/module-map.md), protocol seams table).

```swift
// Packages/TidyKit/Sources/TidyCore/Browser/BrowserAdapter.swift
public struct BrowserTab: Sendable, Equatable {
    public let url: String
    public let title: String
    public init(url: String, title: String) { self.url = url; self.title = title }
}

public protocol BrowserAdapter: Sendable {
    var browserId: String { get }               // 'chrome' → activity_samples.browser
    var bundleId: String { get }                // 'com.google.Chrome'
    func isRunning() -> Bool
    /// Active-tab URL + title. Needs only the Automation grant. nil = no window.
    func activeTab() throws -> BrowserTab?
    /// Visible page text. Needs the JS toggle too. nil = unavailable → caller degrades.
    func visiblePageText() throws -> String?
}
```

- **v1:** exactly one implementation, `ChromeAdapter` (§4). The watcher selects it by matching the
  frontmost app's bundle id against a registry of known browser adapters; `config.json` records the
  chosen browser so a teammate can pick theirs later ([../../PLAN.md](../../PLAN.md) §2, §10).
- **Later (post-v1):** Safari, Firefox, and Dia arrive as **WebExtension + native messaging**
  adapters, not AppleScript — this is also the durable successor path if Chrome ever removes
  `execute … javascript` (§8). Each still conforms to `BrowserAdapter`; only page-text acquisition
  differs. See [../../PLAN.md](../../PLAN.md) §13.
- **Privacy:** consider skipping page-text capture for incognito windows (§2) and, per the
  sensitivity model, remember that all page text passes the **sensitivity gate** before any cloud
  payload is built (guardrail G2). Capturing text ≠ transmitting it.

---

## 8. Risk: Google can break `execute javascript`

`execute … javascript` over Apple Events has been stable for years but is **Google's to remove or
re-gate** — it lives behind a hidden developer toggle precisely because Google treats it as a
power-user feature ([../../PLAN.md](../../PLAN.md) §12, Risks). TidyTime is built to survive that:

1. **Graceful fallback is already the default path** (§6): lose page text, keep URL + title, keep
   classifying. No crash, no user-facing failure.
2. **The `BrowserAdapter` seam** (§7) means the replacement — a WebExtension that posts page text to
   the app via native messaging — is a new adapter, not a pipeline rewrite.
3. **Detection, not assumption:** every capture cycle re-learns the toggle/permission state and
   surfaces it in the doctor view, so a regression is *visible* the day it happens, not a silent
   data gap discovered weeks later.

---

## 9. Acceptance criteria (Phase 1)

- With Automation granted and the toggle **on**, a real workday reads back as a coherent session
  timeline in the doctor/debug view, **including page-text snapshots** in `page_snapshots`, with
  quiet CPU (guardrail: <~2% avg) — matches the Phase 1 accept bar in [../../PLAN.md](../../PLAN.md)
  §11.
- Re-focusing an unchanged tab creates **no** new `page_snapshots` row (dedupe by `content_hash`).
- Stored `text_bytes ≤ 4096` for every row; no row splits a Unicode scalar (round-trips cleanly).
- With the toggle **off**, capture continues with URL + title only, `page_snapshots` gains no rows,
  and the doctor view reports `chromeJavaScript: off` — no error dialog is shown.
- With Automation **denied**, the adapter reports `.automationDenied` and the doctor view flags the
  Automation → Chrome permission (hand-off to [macos-permissions-tcc.md](macos-permissions-tcc.md)).
- Guardrail check: `TidyCapture` sources contain **no** `CGWindowList*` call and request **no**
  Screen Recording (G3) — see [macos-permissions-tcc.md](macos-permissions-tcc.md) §1 and
  [../guardrails.md](../guardrails.md).
