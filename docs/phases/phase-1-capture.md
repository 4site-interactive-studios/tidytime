# Phase 1 — Capture

Bank the raw day: the app/window watcher, idle/away + lock/sleep handling, the Chrome adapter
(URL, title, page text), sessionization into a coherent timeline, and the retention purge — so
every later phase has real history to get smarter against.

**Related:** [../README.md](../README.md) (doc index) ·
[../../PLAN.md](../../PLAN.md) §4, §11 (Phase 1) ·
[../architecture/capture-layer.md](../architecture/capture-layer.md) (watcher, idle, meeting state) ·
[../reference/chrome-scripting.md](../reference/chrome-scripting.md) (AppleScript into Chrome) ·
[../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md) (Accessibility / Automation) ·
[../architecture/data-model.md](../architecture/data-model.md) (capture tables) ·
[phase-0-skeleton.md](phase-0-skeleton.md) (previous) · [../guardrails.md](../guardrails.md) (G3, G8, G9)

---

## Status: as built (2026-07-23)

> ✅ **Logic complete + unit-tested** (46 tests total, 73.9% line coverage). Shipped: the
> `v1-capture` migration + records/DAOs, `ContextKey`, `PageTextPolicy` (truncate + sha256 dedup),
> `Sessionizer` (detour absorption + min-session drop), `AwayGapDetector`, `SampleRecorder`,
> `SessionBuildJob`, and `RetentionJob`. Live OS adapters (`ChromeAdapter`, `FrontmostReader` via
> NSWorkspace+Accessibility, `AppWatcher`, `IdleReader`, `PowerObserver`) are compile-checked behind
> `#if canImport(AppKit)`. Full write-up: [../retrospectives/phase-1.md](../retrospectives/phase-1.md).
>
> ⚠️ **Manual acceptance (needs a running app + TCC grants):** the "full workday reads back as a
> coherent session timeline, quiet CPU, no gaps across sleep/lock" criterion requires the live
> watchers on a real Mac. The samples→timeline transform is tested with synthetic data; the live
> watchers producing faithful samples is unproven in a headless session.

---

## Scope (in / out)

**In:**

- **App/window watcher** — `NSWorkspace.didActivateApplicationNotification` for foreground app
  changes; focused window title via the Accessibility API (`AXUIElement`), **never** `CGWindowList`
  (guardrail G3). Sample on every switch **plus** a 30-second heartbeat.
- **Idle & away** — `CGEventSource` idle seconds (polled on the heartbeat cadence); sleep/wake and
  screen-lock/unlock close sessions cleanly and write `away_gaps`.
- **Chrome adapter** — active-tab URL + title (Automation grant) and visible page text
  (`document.body.innerText`, the "Allow JavaScript from Apple Events" toggle), snapshot/dedupe into
  `page_snapshots`, silent degrade to URL+title. Full detail:
  [../reference/chrome-scripting.md](../reference/chrome-scripting.md).
- **Toggle walkthrough** — detect whether "Allow JavaScript from Apple Events" is on; if off, walk
  the user through View → Developer once; degrade silently meanwhile.
- **Sessionization** — collapse contiguous `activity_samples` into `sessions` (`kind='screen'`),
  tolerating brief detours (< `sessionization.detour_tolerance_seconds`, default 120 s).
- **Retention job** — scheduled purge of raw `activity_samples` + `page_snapshots` past the window
  (default 90 days), guardrail G9.
- **Doctor additions** — permission statuses (Accessibility, Automation → Chrome, the Chrome JS
  toggle), a readable **session timeline** for a chosen day, live capture health.

**Out (later phases):**

- **Attribution** — `sessions.client_id/project_id/task_id`, `confidence`, `produced_by_rung`,
  `rationale` stay **NULL** this phase. Entity resolution + the classification ladder are **Phase 5**
  ([../architecture/understand-layer.md](../architecture/understand-layer.md)).
- **The away *prompt* UI** ("break / call / other") and its attribution write-back — **Phase 3**
  ([phase-3-meetings-calendar.md](phase-3-meetings-calendar.md)). Phase 1 only *records* the gap;
  `away_gaps.attribution` stays NULL.
- **Meeting-state inference** — depends on calendar (an event happening now), which lands in
  **Phase 3**. Phase 1 sessionizes screen activity only; meeting sessions come later.
- **Non-Chrome browsers** — the `BrowserAdapter` seam exists; only `ChromeAdapter` ships (PLAN §4).
- Any API/network, any AI.

---

## Prerequisites

- **Phase 0 complete** ([phase-0-skeleton.md](phase-0-skeleton.md)): signed app, DB with the
  `v1-capture` migration, config load, `SecretStore`, `doctor`.
- **Stable signing verified (G7)** — TCC grants must survive rebuilds, or the watcher loses
  Accessibility mid-development ([../build/signing-and-tcc.md](../build/signing-and-tcc.md)).
- **Accessibility grant** — first run prompts System Settings → Privacy → Accessibility
  ([../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md)).
- **Automation → Google Chrome grant** — prompted on first Apple Event to Chrome; needs
  `NSAppleEventsUsageDescription` in `Info.plist`.
- **Chrome's "Allow JavaScript from Apple Events"** toggle for page text (degrades gracefully if
  off) — [../reference/chrome-scripting.md](../reference/chrome-scripting.md) §3.

---

## Work items

Grouped by target. Regenerate with `make generate` after adding files. Concurrency: the capture
pipeline is an **actor** with batched writes; `NSAppleScript` and `AXUIElement` are not thread-safe
and are pinned to the main actor ([../conventions/swift-style.md](../conventions/swift-style.md),
[../reference/chrome-scripting.md](../reference/chrome-scripting.md) §4).

### TidyCapture (`Packages/TidyKit/Sources/TidyCapture/`)

- [ ] `Watcher/AppActivationWatcher.swift` — subscribes to
      `NSWorkspace.shared.notificationCenter` `didActivateApplicationNotification`; emits the
      frontmost app's bundle id + name.
- [ ] `Watcher/WindowTitleReader.swift` — focused window title via `AXUIElement`
      (`kAXFocusedWindowAttribute` → `kAXTitleAttribute`). **No `CGWindowList*` call** (guardrail G3;
      a lint/grep test enforces this — [../guardrails.md](../guardrails.md) G3).
- [ ] `Watcher/Heartbeat.swift` — single 30-second timer emitting `source='heartbeat'` samples so
      long uninterrupted focus still records duration.
- [ ] `Watcher/CaptureCoordinator.swift` — the capture **actor**: consumes activation + heartbeat +
      idle/power events, closes the previous `activity_samples` row (sets `ended_at`), opens the
      next, invokes the browser adapter when the frontmost app is a known browser, and flushes
      **batched** writes in one WAL transaction (performance bar: <~2% avg CPU,
      [../architecture/overview.md](../architecture/overview.md#performance-bar)).
- [ ] `Browser/ChromeAdapter.swift`, `Browser/ChromeScripts.swift`, `Browser/PageSnapshotCapturer.swift`
      — verbatim contracts in [../reference/chrome-scripting.md](../reference/chrome-scripting.md)
      §4–§6 (compile `NSAppleScript` once; map errors by **message substring**; truncate to 4096
      UTF-8 bytes on a scalar boundary; `content_hash` dedupe; silent degrade).
- [ ] `Browser/ToggleWalkthrough.swift` — the `execute … javascript "1"` probe and the one-time
      View → Developer walkthrough; sets the `chromeJavaScript` doctor flag
      ([../reference/chrome-scripting.md](../reference/chrome-scripting.md) §6).
- [ ] `Idle/IdleMonitor.swift` — `CGEventSource.secondsSinceLastEventType(.combinedSessionState,
      eventType: .null)` polled on the heartbeat cadence; crossing `capture.idle_threshold_seconds` (default 600 s / 10 min) ends
      the current session and opens an `away_gaps` row with `cause='idle'`.
- [ ] `Idle/PowerLockObserver.swift` — sleep/wake via
      `NSWorkspace.shared.notificationCenter` (`willSleepNotification`/`didWakeNotification`) and
      screen lock via the `com.apple.screenIsLocked` / `screenIsUnlocked` distributed notifications;
      each closes the open sample/session and writes `away_gaps` with `cause='sleep'`/`'lock'`.

### TidyUnderstand (`Packages/TidyKit/Sources/TidyUnderstand/`) — sessionizer seam

- [ ] `Sessionization/Sessionizer.swift` — folds ordered `activity_samples` for a day into
      `sessions` (`kind='screen'`, `started_at`/`ended_at`/`duration_seconds`, `title`,
      `context_key` = normalized dominant signal such as URL host, `primary_app`), merging detours
      shorter than `sessionization.detour_tolerance_seconds`. Attribution columns stay **NULL** (Phase 5 fills them).

> **Seam note:** [module-map.md](../architecture/module-map.md) lists `TidyUnderstand` as building
> in Phase 5. Phase 1 introduces **only** the sessionizer, because [../../PLAN.md](../../PLAN.md) §11
> Phase 1 lists "sessionization" and the acceptance requires a session timeline. Entity resolution,
> the classification ladder, and the sensitivity gate remain Phase 5. Flagged in the build handoff.

### TidyStore (`Packages/TidyKit/Sources/TidyStore/`)

- [ ] `DAOs/ActivitySampleDAO.swift`, `DAOs/PageSnapshotDAO.swift`, `DAOs/SessionDAO.swift`,
      `DAOs/AwayGapDAO.swift` — insert/close/query helpers over the `v1-capture` tables.
      `PageSnapshotDAO.hasRecent(url:contentHash:)` backs the dedupe
      ([../reference/chrome-scripting.md](../reference/chrome-scripting.md) §5).
- [ ] `Retention/RetentionJob.swift` — deletes `activity_samples` older than
      `retention_days.activity_samples` (default 90); `page_snapshots` cascade-delete via their FK
      (`ON DELETE CASCADE`). Runs on a schedule (daily, and once at launch). Extensible to
      `slack_messages`/`transcript_utterances` when those tables exist (Phases 3–4). Guardrail G9,
      [../architecture/data-model.md](../architecture/data-model.md#retention).

### App shell (`App/`)

- [ ] `App/CaptureController.swift` — starts/stops the `CaptureCoordinator` with the menu-bar
      capturing/paused state; wires the pause control in `MenuBarContent`.
- [ ] `App/DoctorView.swift` (extend) — add Accessibility / Automation-Chrome / `chromeJavaScript`
      statuses and a **day timeline** panel: for a chosen day, list `sessions` with times, app,
      title, `context_key`, and a page-snapshot count.
- [ ] `App/Info.plist` (extend) — finalize `NSAppleEventsUsageDescription` (why TidyTime scripts
      Chrome/System Events) so the Automation prompt reads sensibly.

---

## Data model

- **Tables touched:** `activity_samples` (write), `page_snapshots` (write), `sessions` (write,
  attribution columns NULL), `away_gaps` (write, `attribution`/`client_id` NULL until Phase 3),
  `sync_state` (untouched this phase). All defined in
  [data-model.md](../architecture/data-model.md) — Capture tables.
- **GRDB migration name:** **none new** — the schema was created by **`v1-capture`** in Phase 0
  ([phase-0-skeleton.md](phase-0-skeleton.md)). Phase 1 is the write path. If a Phase-1 need
  surfaces (e.g. an extra index), it is a **new** migration (`v1-capture-idx…`), **never** an edit
  to the shipped `v1-capture` ([data-model.md](../architecture/data-model.md#migrations)).
- **Units/conventions:** timestamps are `INTEGER` Unix epoch **seconds, UTC**; durations are
  **seconds**; booleans `0/1` ([data-model.md](../architecture/data-model.md#conventions)).

Sample lifecycle (one row per contiguous frontmost context):

```sql
-- open a new sample on app/window switch
INSERT INTO activity_samples
  (started_at, app_bundle_id, app_name, window_title, is_browser, browser, url, source, created_at)
VALUES (:now, :bundle, :name, :title, :isBrowser, :browser, :url, 'switch', :now);

-- close the previous sample (also on idle/lock/sleep)
UPDATE activity_samples SET ended_at = :now WHERE id = :prevId AND ended_at IS NULL;

-- record an away gap when idle crosses the threshold / on lock / on sleep
INSERT INTO away_gaps (started_at, ended_at, duration_seconds, cause, created_at)
VALUES (:gapStart, :gapEnd, :gapEnd - :gapStart, :cause, :now);   -- cause: 'idle'|'lock'|'sleep'
```

Retention purge (G9), run on schedule:

```sql
-- page_snapshots rows cascade via their FK ON DELETE CASCADE
DELETE FROM activity_samples
WHERE started_at < :cutoff;                      -- cutoff = now - retention_days*86400
```

---

## Key references

- [../architecture/capture-layer.md](../architecture/capture-layer.md) — watcher, idle/away, and the
  meeting-state seam.
- [../reference/chrome-scripting.md](../reference/chrome-scripting.md) — the full Chrome adapter:
  scripts, `NSAppleScript` usage, error mapping, snapshot/dedupe policy, degrade, toggle detection.
- [../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md) — Accessibility
  (`AXIsProcessTrusted`), Automation prompt flow, and how `doctor` reports each.
- [../architecture/data-model.md](../architecture/data-model.md) — capture-table DDL, indices,
  retention matrix.
- [../architecture/overview.md](../architecture/overview.md#performance-bar) — the <~2% CPU bar and
  the event-driven / heartbeat / batched-write design that holds it.
- [../guardrails.md](../guardrails.md) — G3 (no Screen Recording / `CGWindowList` name), G8 (one
  process), G9 (retention).

---

## Risks

- **Accessibility/Automation grants dropping on rebuild (G7).** Verify stable signing before
  leaning on the watcher; `doctor` surfaces a lost grant instead of a silent data gap
  ([../build/signing-and-tcc.md](../build/signing-and-tcc.md)).
- **Accidental `CGWindowList` reach (G3).** Reading window titles is exactly where a developer
  might grab `kCGWindowName` and trip Screen Recording. The `AXUIElement` route is mandatory; a
  grep guardrail test fails the build if `CGWindowList*` appears in `TidyCapture`
  ([../guardrails.md](../guardrails.md) G3).
- **Chrome scripting is Google's to break.** `execute … javascript` sits behind a hidden toggle;
  the silent URL+title fallback keeps the app working, and the `BrowserAdapter` seam makes a
  WebExtension successor a new adapter, not a rewrite
  ([../reference/chrome-scripting.md](../reference/chrome-scripting.md) §8).
- **Gaps across sleep/lock.** The classic failure is a session left "open" across a sleep so the
  timeline shows a multi-hour block. Every power/lock transition must close the open sample/session
  and (for real absence) write an `away_gap`; the acceptance check exercises exactly this.
- **CPU creep.** Polling too fast (idle) or snapshotting too often blows the <~2% bar. Keep idle
  polling on the 30 s heartbeat, debounce title-change snapshots (~1.5 s), truncate + hash page
  text, and batch writes ([../architecture/overview.md](../architecture/overview.md#performance-bar)).
- **Retention deleting too much / too little.** Cascade behavior and the cutoff arithmetic (epoch
  seconds) are easy to get wrong; the retention test seeds old + recent rows and asserts only the
  old ones (and their cascaded snapshots) are gone.

---

## Acceptance criteria

Verbatim-faithful to [../../PLAN.md](../../PLAN.md) §11 Phase 1 — *"a full workday reads back as a
coherent session timeline in the debug view, including page-text snapshots, with CPU staying quiet
and no gaps across sleep/lock."* Each item is human-verifiable:

- [ ] After a full workday, the **Doctor day-timeline** renders a **coherent session timeline** —
      contiguous `sessions` in order, each with a sensible app/title/`context_key`, no unexplained
      multi-hour blocks.
- [ ] **Page-text snapshots are present** (`page_snapshots` rows) for Chrome sessions where the
      "Allow JavaScript from Apple Events" toggle was on; re-focusing an unchanged tab adds **no**
      new snapshot (dedupe).
- [ ] **CPU stays quiet** — sustained average **< ~2%**, no fan spin — over the day (⚠️ build-time
      check: measure with Instruments / `powermetrics` on the M2-or-newer target).
- [ ] **No gaps across sleep/lock** — sleeping, waking, locking, and unlocking produce clean
      `away_gaps` (`cause` `sleep`/`lock`) and leave the timeline with no dangling open sample and
      no overlapping/duplicate sessions.
- [ ] **Idle** beyond `capture.idle_threshold_seconds` ends the current session and opens an `away_gaps` row
      (`cause='idle'`); returning opens a fresh sample, not a resurrected one.
- [ ] **Retention** purges `activity_samples`/`page_snapshots` older than the window (seed old rows,
      run the job, assert gone; recent rows and their snapshots remain).
- [ ] With the toggle **off** or Automation **denied**, capture **continues with URL + title only**,
      `page_snapshots` gains no rows, and `doctor` reports the degraded state — no error dialog.

---

## Definition of done

- `make build` compiles and `make test` passes, including: a sessionizer test (fixture samples →
  expected sessions, detours merged), a retention test (G9), the `CGWindowList` grep guardrail test
  (G3), and Chrome-adapter tests against **recorded** AppleScript replies (no live browser —
  [../reference/chrome-scripting.md](../reference/chrome-scripting.md), [../build/testing-strategy.md](../build/testing-strategy.md)).
- The watcher runs all day inside the single menu-bar process (G8) under the <~2% CPU bar; pause in
  the menu bar stops capture.
- `activity_samples`, `page_snapshots`, `sessions`, and `away_gaps` populate correctly; attribution
  columns remain NULL (Phase 5 owns them).
- The Chrome adapter degrades silently to URL+title on any failure and surfaces the state in
  `doctor`; the one-time toggle walkthrough works.
- No guardrail regression: no `CGWindowList` name usage / no Screen Recording ask (G3); no secret
  in logs (page text is captured but not transmitted — the sensitivity gate that guards cloud
  payloads is Phase 6, G2); no
  helper/daemon (G8); retention job active (G9).
- No new migration, or — if unavoidable — a **new** migration that does not edit `v1-capture`;
  [data-model.md](../architecture/data-model.md) updated in the same change only if the schema
  changed.
- New user-facing behavior (the timeline, degrade states) is reflected in this doc's acceptance
  criteria; [CLAUDE.md](../../CLAUDE.md)'s phase table link resolves to this file.
