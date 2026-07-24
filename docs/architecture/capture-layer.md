# Capture layer (TidyCapture)

The on-device capture design: how TidyTime observes the foreground app, window titles, Chrome
page text, idle/away, power/lock transitions, and meeting state — writing `activity_samples`,
`page_snapshots`, and `away_gaps` — all without Screen Recording and under the ~2% CPU bar.

**Related:** [../README.md](../README.md) (doc index) ·
[../../PLAN.md](../../PLAN.md) §4 (canonical capture spec) ·
[overview.md](overview.md) (five layers & data flow) ·
[data-model.md](data-model.md) (exact tables/columns) ·
[../reference/chrome-scripting.md](../reference/chrome-scripting.md) (Chrome adapter mechanics) ·
[../guardrails.md](../guardrails.md) (G3 no Screen Recording, G8 one process, G9 retention)

---

## Scope & guardrails

`TidyCapture` is the CAPTURE box of [overview.md](overview.md): local, on-device, no network.
It produces the raw signal the rest of the pipeline distills. It **never** classifies, calls a
cloud model, or touches Productive.

Hard rules this layer lives under:

- **G3 — No Screen Recording.** Window titles come from the Accessibility API
  (`AXUIElement`), **never** `CGWindowListCopyWindowInfo`'s `kCGWindowName`. A `CGWindowList*`
  name-reading call is a release-blocking lint failure. See [../guardrails.md](../guardrails.md) G3.
- **G8 — One process.** All monitors run inside the menu-bar app; no daemon, no XPC helper.
- **G9 — Retention.** `activity_samples`, `page_snapshots` are raw high-volume tables purged
  after the retention window (default 90 days). Capture writes them; the retention job
  (TidyStore) purges them. See
  [data-model.md](data-model.md#retention-phase-1-job-enforced-ongoing--guardrail-g9).
- **Performance bar.** Event-driven + one 30 s heartbeat + batched writes, under ~2% avg CPU
  ([overview.md](overview.md#performance-bar)).

Tables this layer writes (defined in [data-model.md](data-model.md)):
`activity_samples`, `page_snapshots`, `away_gaps`. It does **not** write `sessions` — that is
the sessionizer's job (see [Boundary events → sessionization](#boundary-events--sessionization)).

## Component map

```
                       ┌───────────────────────────────┐
   NSWorkspace  ──────▶│                               │
   activation          │      CaptureCoordinator       │──▶ TidyStore DAOs
   sleep/wake          │      (actor: owns the open    │    (batched INSERTs,
   DistributedNC ─────▶│       sample + batch buffer)  │     one WAL txn)
   lock/unlock         │                               │
                       └──┬─────────┬─────────┬────────┘
   30 s heartbeat ────────┘         │         └──────── MeetingStateProvider ──▶ live signal
   (Timer)                          │                    (frontmost app + calendar_events)
                          ┌─────────┴─────────┐
                   WindowTitleReader    BrowserAdapter (ChromeAdapter)
                   (AXUIElement)        (AppleScript / Apple Events)
                          │                    │
                   IdleMonitor          page_snapshots
                   (CGEventSource)
                          │
                   away_gaps
```

File manifest — `Packages/TidyKit/Sources/TidyCapture/`:

| File | Type | Responsibility |
|---|---|---|
| `CaptureCoordinator.swift` | `actor` | Single serialization point. Owns the current open `activity_samples` row, the write batch, idle/away state machine. All monitors funnel events here. |
| `AppActivationWatcher.swift` | class | Subscribes to `NSWorkspace.didActivateApplicationNotification`; forwards `(bundleId, name, pid)` to the coordinator. |
| `WindowTitleReader.swift` | struct | Reads the focused window title via `AXUIElement` for a pid. No `CGWindowList`. |
| `BrowserAdapter.swift` | `protocol` | Active-tab `url` / `title` / `pageText`. v1 impl `ChromeAdapter`. |
| `ChromeAdapter.swift` | struct | AppleScript over Apple Events; page text via `execute javascript`. See [../reference/chrome-scripting.md](../reference/chrome-scripting.md). |
| `IdleMonitor.swift` | struct | `CGEventSource` idle seconds; polled on the heartbeat tick. |
| `PowerStateMonitor.swift` | class | `NSWorkspace` sleep/wake + `DistributedNotificationCenter` screen lock/unlock. |
| `MeetingStateProvider.swift` | class | Live in-memory meeting-state inference; publishes `MeetingState`. Persists nothing. |
| `CaptureController.swift` | class | Public entry point: `start()`/`stop()`, reads kill switches, wires monitors to the coordinator. |

Config (thresholds + kill switches) is a `Config.Capture` value owned by `TidyCore`; TidyCapture
reads it, never parses files itself (guardrail G6 — no secrets here anyway, but the rule holds).

## Actor-based pipeline

Swift 6 strict concurrency ([../conventions/swift-style.md](../conventions/swift-style.md)):
make **`CaptureCoordinator` an `actor`** so the current-open-sample state and the write batch
have exactly one owner and no lock is needed. Monitors are cheap event sources that `await`
into the actor; the actor decides what to persist.

```swift
actor CaptureCoordinator {
    private var openSample: ActivitySampleDraft?   // the one row with ended_at == nil
    private var batch: [ActivitySampleDraft] = []
    private var awayState: AwayState = .active      // .active | .idle(since:) etc.

    /// App switch (from NSWorkspace, main thread) → close current, open new.
    func onAppActivated(bundleId: String, appName: String, pid: pid_t) async { … }

    /// 30 s tick: re-read focused title/URL; if the context changed, roll the sample;
    /// also poll idle seconds and drive the away state machine.
    func onHeartbeat() async { … }

    /// Idle/power/lock transitions → close sample cleanly, open/close an away gap.
    func onAwayStart(cause: AwayCause, at: Int) async { … }
    func onAwayEnd(at: Int) async { … }

    func flush() async { /* one WAL transaction via TidyStore DAO */ }
}
```

Concurrency boundaries the implementer must respect:

- `NSWorkspace` and `DistributedNotificationCenter` deliver on the **main** thread. Handlers
  should do nothing but `Task { await coordinator.onAppActivated(…) }`.
- **`AXUIElement` calls are not thread-safe per element**; keep all Accessibility reads on a
  single serialized context (call them from inside the actor, or from one dedicated executor).
  ⚠️ Build-time check: confirm AX read latency off the main thread on target hardware.
- **AppleScript / `NSAppleScript` must not run on an actor's cooperative thread** if it blocks;
  dispatch Chrome scripting to a dedicated queue and `await` the result. See
  [../reference/chrome-scripting.md](../reference/chrome-scripting.md).
- The coordinator is the only writer, so the batch buffer and `openSample` are race-free by
  construction.

## App & window watcher → `activity_samples`

**App switches** come from `NSWorkspace.didActivateApplicationNotification` (posted on
`NSWorkspace.shared.notificationCenter`). This fires when the *frontmost application* changes —
**not** when the window or tab changes within the same app. Within-app changes (a new Chrome
tab, a different Google Doc) are caught by the heartbeat re-read (≤30 s latency, acceptable for
time attribution).

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    else { return }
    Task { await coordinator.onAppActivated(
        bundleId: app.bundleIdentifier ?? "", appName: app.localizedName ?? "", pid: app.processIdentifier) }
}
```

**Focused window title** via Accessibility (guardrail G3 — no `CGWindowList`):

```swift
func focusedWindowTitle(pid: pid_t) -> String? {
    let appEl = AXUIElementCreateApplication(pid)
    var win: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
          let window = win else { return nil }
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
    else { return nil }
    return title as? String
}
```

Requires the Accessibility TCC grant (System Settings → Privacy → Accessibility); the app
prompts on first run and `doctor` surfaces the status. See
[../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md).

### Sampling model

One `activity_samples` row is the currently-frontmost context; its `ended_at` is `NULL` while
open (see column semantics in [data-model.md](data-model.md#capture-tables-phase-1)).

| Trigger | Coordinator action | `source` |
|---|---|---|
| App activation notification | Close open sample (`ended_at = now`), open a new one for the new app + title (+ URL if browser). | `'switch'` |
| 30 s heartbeat, context **changed** (title/URL differs from open sample) | Close open sample, open a new one. | `'heartbeat'` |
| 30 s heartbeat, context **unchanged** | Leave the open sample open (its span simply grows); no new row. Also poll idle. | — |
| Idle / sleep / lock crosses threshold | Close open sample cleanly; begin an away gap (below). | — |

Row mapping (columns from [data-model.md](data-model.md)):

```swift
ActivitySample(
    started_at: switchTime,           // context became frontmost (epoch seconds, UTC)
    ended_at:   nil,                  // set when superseded
    app_bundle_id: app.bundleId,
    app_name:   app.name,
    window_title: title,              // nil if AX unavailable
    is_browser: adapter != nil ? 1 : 0,
    browser:    isBrowser ? "chrome" : nil,
    url:        isBrowser ? tabURL : nil,
    source:     "switch",             // or "heartbeat"
    created_at: now)
```

**Batching (performance bar).** Drafts accumulate in the actor and flush in one WAL transaction
on a short cadence (e.g. every few seconds or every N rows, whichever first) and always on
`stop()`, sleep, and app termination — so bursty app-switching is a handful of INSERTs, not one
per event. Never leave the open sample unflushed across a sleep transition.

## Chrome adapter → `page_snapshots`

For the active tab, `ChromeAdapter` (behind `BrowserAdapter`) uses AppleScript over Apple
Events to read `url` and `title` with no browser config, and `execute javascript` to capture
`document.body.innerText`. Full mechanics, the one-time "Allow JavaScript from Apple Events"
toggle, the Automation TCC prompts, and graceful degradation live in
[../reference/chrome-scripting.md](../reference/chrome-scripting.md).

Capture policy (from [../../PLAN.md](../../PLAN.md) §4):

1. Snapshot `document.body.innerText` **on tab focus** and **on meaningful title/URL change**
   (detected at the heartbeat) — not continuously.
2. **Truncate** to `capture.page_text_max_bytes` (~4 KB / 4096 bytes → `page_snapshots.text`,
   with `text_bytes` recorded).
3. **Content-hash** (sha256) the text → `page_snapshots.content_hash`. If the hash matches the
   most recent snapshot for that URL, **skip the store** (dedupe; a reload or revisit doesn't
   re-persist identical text).
4. If the JS toggle is off or scripting fails, **degrade silently** to URL + title only (the
   `activity_samples` row still carries `url`); no `page_snapshots` row is written.

Each snapshot FKs to its sample: `page_snapshots.sample_id → activity_samples.id`
(`ON DELETE CASCADE`, so retention purge of a sample drops its snapshots automatically).

```swift
// after the sample for a Chrome tab is opened/rolled:
if killSwitches.chromePageText, let snap = try await chrome.pageText(maxBytes: cfg.pageTextMaxBytes) {
    let hash = sha256(snap.text)
    if hash != lastHash(forURL: snap.url) {
        try store.insertPageSnapshot(PageSnapshot(
            sample_id: openSampleId, captured_at: now, url: snap.url, title: snap.title,
            content_hash: hash, text: snap.text, text_bytes: snap.text.utf8.count))
    }
}
```

`BrowserAdapter` is the protocol seam that lets Safari/Firefox/Dia land later without touching
this pipeline (see [module-map.md](module-map.md#protocol-seams-the-extension-points)).

## Idle & away → `away_gaps`

**Idle detection** uses `CGEventSource` seconds-since-last-input, polled on the heartbeat tick
(not a tight loop). Threshold defaults to **10 minutes** (`capture.idle_threshold_seconds` =
600).

```swift
// "any input event" idle seconds; ⚠️ Build-time check: confirm the kCGAnyInputEventType
// bridging and the source-state constant on the target macOS.
let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                   eventType: CGEventType(rawValue: ~0)!)
```

Away state machine (drives `away_gaps`, columns in
[data-model.md](data-model.md#capture-tables-phase-1)):

| Transition | Detected by | Action |
|---|---|---|
| **Idle start** | idle seconds ≥ threshold at a heartbeat | Close the open sample at `now - idle` (the block ended when input stopped, not when we noticed). Begin an away gap `cause = 'idle'`, `started_at = now - idle`. |
| **Idle end** | input resumes (idle drops below threshold) | Finalize the away gap: `ended_at = now`, `duration_seconds`, insert row. Reopen sampling for the current frontmost app. Enqueue the away prompt (surface). |
| **Sleep** | `NSWorkspace.willSleepNotification` | Flush + close the open sample; begin an away gap `cause = 'sleep'`. |
| **Wake** | `NSWorkspace.didWakeNotification` | Finalize the sleep gap; resume sampling. |
| **Screen lock** | `com.apple.screenIsLocked` (DistributedNC) | Close the open sample; begin an away gap `cause = 'lock'`. |
| **Screen unlock** | `com.apple.screenIsUnlocked` (DistributedNC) | Finalize the lock gap; resume sampling. |

`away_gaps.attribution` / `note` / `client_id` stay `NULL` at capture time; the **away prompt**
in TidySurface fills them ("break / call + who / other"). See
[surface-layer.md](surface-layer.md).

Precedence: if a lock or sleep arrives while already idle, keep the **earliest** boundary and
the more specific cause — a single gap, not overlapping ones. The coordinator holds one
`awayState`, so overlaps collapse naturally.

## Sleep/wake & screen-lock notifications

```swift
// Sleep / wake — NSWorkspace notification center (main thread).
let wc = NSWorkspace.shared.notificationCenter
wc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
    Task { await coordinator.onAwayStart(cause: .sleep, at: nowEpoch()) } }
wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    Task { await coordinator.onAwayEnd(at: nowEpoch()) } }

// Screen lock / unlock — DistributedNotificationCenter.
// ⚠️ Build-time check: these names are widely used but undocumented by Apple; verify on the
// target macOS and treat a no-fire gracefully (idle still catches the gap).
let dc = DistributedNotificationCenter.default()
dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
    Task { await coordinator.onAwayStart(cause: .lock, at: nowEpoch()) } }
dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
    Task { await coordinator.onAwayEnd(at: nowEpoch()) } }
```

The point of closing sessions cleanly on these transitions is the Phase 1 acceptance criterion:
**no gaps across sleep/lock** ([../../PLAN.md](../../PLAN.md) §11). A day with three lunch locks
and an overnight sleep must read back as clean bounded blocks + labeled away gaps, not one
smeared 18-hour sample.

## Boundary events → sessionization

Capture emits **boundaries**; the sessionizer (TidyUnderstand, see
[understand-layer.md](understand-layer.md)) turns samples between boundaries into `sessions`
rows. This is the seam that keeps capture dumb and testable.

A **hard session boundary** is any of: app switch that changes context beyond the ~2-minute
detour tolerance, an `away_gaps` row (idle/lock/sleep), or a Chrome context change to a
different client host. Capture guarantees the raw material — correctly-bounded
`activity_samples` and `away_gaps` — is on disk; it does not compute the sessions itself.

> Note on phasing: `activity_samples`, `page_snapshots`, `away_gaps`, and `sessions` are all in
> the Phase 1 table set ([data-model.md](data-model.md#which-phase-creates-what)), and Phase 1's
> acceptance requires a coherent **session** timeline. TidyCapture delivers the samples/gaps;
> the sessionization pass that fills `sessions` is described in
> [understand-layer.md](understand-layer.md). Do not have TidyCapture write `sessions` directly.

## Meeting-state inference

Meeting state is a **live, in-memory signal**, not a persisted table (there is no meeting-state
table in [data-model.md](data-model.md) — do not invent one). `MeetingStateProvider` publishes a
`MeetingState` computed from two inputs:

1. **Calendar:** a `calendar_events` row whose `[start_at, end_at]` spans *now*, status
   `confirmed`/`tentative` (available once Phase 3 ingest has run).
2. **Frontmost app:** the current `activity_samples` context is a conferencing surface —
   Zoom (`us.zoom.xos`), a Slack huddle (`com.tinyspeck.slackmacgap` frontmost during an event),
   or **Google Meet detected via the Chrome adapter URL** (`meet.google.com`), not a separate
   app. ⚠️ Build-time check: confirm bundle ids and that Slack-huddle-specific detection is
   feasible; if not, fall back to "Slack frontmost during a calendar event."

Two consumers, both read-only against this signal:

- **Nudge suppression (surface).** No nudge fires while `MeetingState.isInMeeting` (also
  enforced by the calendar-window rule in [surface-layer.md](surface-layer.md)).
- **Concurrent-work labeling (understand).** Screen activity during a meeting is labeled
  in-meeting *context* rather than counted as separate parallel work, so the meeting split
  (from Fathom, [suggestion-engine.md](suggestion-engine.md)) stays authoritative for that span.

Mic-in-use detection via CoreAudio is explicitly **out of scope for v1**
([../../PLAN.md](../../PLAN.md) §4) — a possible later refinement.

## Kill switches & config

Every capture source is independently disableable via `config.capture.kill_switches` without a
rebuild — for debugging, privacy (e.g. turn off page text), or isolating a misbehaving monitor.
Each monitor checks its flag at `start()` and skips wiring if off.

The relevant `capture` config keys (the canonical schema is `config.example.json`; the detour
tolerance lives under the separate `sessionization` block, since the Sessionizer is a
`TidyUnderstand` concern):

```json
{
  "capture": {
    "browser": "chrome",
    "heartbeat_seconds": 30,
    "detection_interval_seconds": 1.0,
    "content_interval_seconds": 20.0,
    "separate_chats_by_path": true,
    "idle_threshold_seconds": 600,
    "page_text_max_bytes": 4096,
    "kill_switches": {
      "app_watcher": true,
      "chrome": true,
      "calendar": true,
      "fathom": true,
      "slack": true
    }
  },
  "sessionization": {
    "detour_tolerance_seconds": 120,
    "min_session_seconds": 60
  }
}
```

**Tiered capture (`CaptureCoordinator`).** Two change-gated cadences replace a single heartbeat:
a fast **detection** poll (`detection_interval_seconds`, default 1s, + on every app-activation event)
reads app + window title + browser active-tab URL/title and records a new `activity_samples` row
**only when the `(app, window_title, url)` signature changes** — so a within-app switch (chat→chat,
tab→tab) yields a distinct sample the instant the title/URL differs, while sitting still stays one
open sample. A slow **content** poll (`content_interval_seconds`, default 20s, + once on a browser
change) does the expensive `document.body.innerText` capture, deduped by hash. (`heartbeat_seconds`
is legacy.) The `min_session_seconds` floor still drops sub-minute runs as noise, and distinguishing
two views within an app requires the app's title/AX to actually differ.

**Grouping altitude.** Sessions group by a *fine* key (`ContextKey.grouping`) = coarse key
(`web:host` / `app:bundle`, kept on the session for rung-1 rules) + normalized title + (when
`separate_chats_by_path` is on) the browser **URL path**. The path folds in the chat/doc id
(`claude.ai/chat/<id>`) so two chats sharing a title are distinct sessions, while **query + fragment
are dropped** so per-message churn doesn't fragment. Native apps have no URL → title-only (two
same-title native chats can't be separated without app-specific AX). Set `separate_chats_by_path:
false` to group by title only (fewer, coarser sessions).

Semantics: a `kill_switches` flag set `false` disables that source cleanly — e.g. `chrome: false`
stops the Chrome adapter (no URL/title sampling and no `page_snapshots`); the ingest switches
(`calendar`, `fathom`, `slack`) gate their respective sync engines (Phases 3–4). The menu bar
"pause capture" is a global stop that halts the whole coordinator, distinct from these per-source
switches.

## Acceptance criteria (Phase 1)

From [../../PLAN.md](../../PLAN.md) §11 — verifiable in the `doctor` view without reading Swift:

- [ ] A full workday reads back as a coherent **session timeline**, including page-text
      snapshots, in the debug view.
- [ ] **No gaps across sleep/lock**: lunch locks and overnight sleep appear as bounded blocks +
      labeled `away_gaps`, not smeared samples.
- [ ] Idle beyond 10 min ends the block and records an `away_gaps` row with the right `cause`.
- [ ] Chrome tabs contribute URL + title always, and page text when the JS toggle is on;
      degrade silently to URL+title when off (no crash, no missing samples).
- [ ] **No `CGWindowList` name usage anywhere** in `TidyCapture` (guardrail G3 lint test green).
- [ ] Sustained **average CPU under ~2%** on M2-or-newer during a normal day
      ([overview.md](overview.md#performance-bar)).

## See also

- Chrome scripting mechanics & the JS toggle → [../reference/chrome-scripting.md](../reference/chrome-scripting.md)
- Permissions (Accessibility, Automation, TCC durability) → [../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md)
- What consumes the samples → [understand-layer.md](understand-layer.md), [overview.md](overview.md)
- Exact columns → [data-model.md](data-model.md)
- Targets & the `BrowserAdapter` seam → [module-map.md](module-map.md)
