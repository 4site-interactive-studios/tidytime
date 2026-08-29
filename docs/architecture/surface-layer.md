# Surface layer (TidySurface)

The presentation layer: the menu bar icon and popover, live nudges, the away prompt, the
end-of-day recap window, the weekly dashboard, and Settings. It renders what the layers below
have already produced and records the user's decisions — it does **no** network I/O and makes
**no** direct provider calls.

**Related:** [../README.md](../README.md) (doc index) ·
[../../PLAN.md](../../PLAN.md) §9 (canonical surface spec) ·
[overview.md](overview.md) (layers & data flow) ·
[suggestion-engine.md](suggestion-engine.md) (what the recap renders) ·
[data-model.md](data-model.md) (tables read/written) ·
[../guardrails.md](../guardrails.md) (G1, G8 in particular)

---

## 1. The presentation-only contract

`TidySurface` is a reusable SwiftUI library target; the app target **TidyTimeApp** (`App/`)
owns the `MenuBarExtra` scene and wires view models to it. The layer is bound by hard rules
from [module-map.md](module-map.md):

- **No network *from the views*.** This rule used to read "`TidySurface` links neither `TidyIngest`
  nor `TidyAI`, so it cannot reach Productive, Fathom, Google, Slack, Fireworks, or Anthropic."
  That has been false since `AppEnvironment` moved into this target: `Package.swift` lists both
  dependencies, because the environment owns the 300s pipeline and the pipeline ingests.

  The rule that still holds — and the one that mattered — is that **views and view models never
  reach the network.** They read `TidyStore` through injected read models. Everything that talks to
  a provider lives in `AppEnvironment`'s pipeline, on its own schedule.

  Note what changed with it: the module boundary used to *enforce* G1 by construction, and now it
  does not. That enforcement moved to `GuardrailEnforcementTests`, which greps the whole tree rather
  than trusting a link-time edge. A boundary that is documented but not compiled is a comment.
> **Shipping status (alpha, 2026-08-28).** This document describes the layer as designed. Three of
> its subsystems are written, unit-tested, and **have no production call site**, so the tables they
> read stay empty and the UI that renders them stays blank:
>
> | Subsystem | What is missing | Visible effect |
> |---|---|---|
> | Away / idle attribution | `PowerObserver` is never started (`TidyCapture/LiveCapture.swift`) | `away_gaps` is 0 rows; `AwayPrompt` never appears; the context-switch metric loses its idle-clipping input |
> | Nudges | `NudgeEngine` and `NudgePresenter` have no callers | `nudges` is 0 rows; no nudge is ever delivered |
> | The answer half of the learning loop | `AwayResolving` / `NudgeOutcomeRecording` have no reachable UI | those write paths never run |
>
> The recap, suggestions, decisions and the ask-once questions **are** wired as described. Reading
> this file as a description of what runs today, rather than of what it specifies, is the mistake
> it is easiest to make here — the QC pass that found the above made exactly that mistake first.

- **No direct provider calls.** "Open task in Productive" opens a `deep_link` URL in the
  browser via `NSWorkspace.open(_:)` — that is the OS opening a URL, not the app calling an
  API. **v1 never writes to Productive (guardrail [G1](../guardrails.md#g1--v1-never-writes-to-productive));**
  "Log it ✓" flips a local status only.
- **Reads via view models; writes only local rows.** View models read through injected
  read-model protocols backed by `TidyStore` DAOs and `TidySuggest`. User actions write local
  rows only — `suggestions.status`, `decisions`, `nudges.outcome`, `resolution_questions`,
  `away_gaps.attribution`, and `config.json`/Keychain from Settings. The learning loop in
  `TidyUnderstand` consumes `decisions` asynchronously ([understand-layer.md](understand-layer.md));
  the surface never runs classification itself.
- **One process (guardrail [G8](../guardrails.md#g8--one-process-no-background-daemons-v1)).**
  Every window lives in the single menu-bar app. There is no dock app and no `WindowGroup`
  root; windows open on demand from the menu bar.

If a view needs data that isn't in the store yet, that is a gap in `TidySuggest`/`TidyStore`,
**not** a reason for the surface to fetch it.

---

## 2. Scene & view structure

The app declares one `MenuBarExtra` plus on-demand windows. Full-size surfaces (recap,
dashboard) are `Window` scenes opened by id; Settings uses the standard `Settings` scene.

```swift
// App/TidyTimeApp.swift  (target: TidyTimeApp)
@main
struct TidyTimeApp: App {
    @State private var container = AppContainer()          // dependency container, App/

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView()
                .environment(container.menuBar)
        } label: {
            Label("TidyTime", systemImage: container.menuBar.icon.symbolName)
        }
        .menuBarExtraStyle(.window)                         // rich popover, not a plain menu

        // NOTE: the shipped shell does NOT use SwiftUI `Window` scenes. `MenuBarExtra` has no
        // `openWindow` for auxiliary panels in a menu-bar-only app, so `AppLauncher` manages
        // NSWindows directly and caches them by `AppWindow.windowKey`. See App/TidyTimeApp.swift.
    }
}
```

**Recap and Stats are one window, not two.** `MainWindow` hosts them as tabs bound to
`MainWindowModel.tab`, which lives on the app shell rather than in the view so the menu bar can
set it: clicking "Stats…" while the window is open showing the Recap has to *switch the tab*, not
front a window still showing the recap. Rebuilding the window to change tabs would discard the
recap's selected day, and giving them separate cache keys would open a duplicate window.

Both menu items therefore resolve to the same `windowKey` (`"main"`), and the tab assignment happens
**before** the early return for an already-open window — a test pins that ordering, because
reversing the two lines is a silent no-op rather than a compile error.

The away prompt is **not** a SwiftUI scene: it is a small always-available `NSPanel`
(non-activating, floating) presented on return from a gap, because it must appear over other
apps without stealing focus. Nudges are delivered through `UNUserNotificationCenter`, not a
window. Everything else is SwiftUI.

### 2.1 View tree (target `TidySurface`)

```
TidySurface/
  MenuBar/
    MenuBarIcon.swift            enum MenuBarIcon  → SF Symbol + badge
    MenuBarPopoverView.swift     "today so far", pending count, pause, open recap/dashboard/settings
    TodaySoFarView.swift         observed-vs-logged bar + numbers
  Nudge/
    NudgePresenter.swift         builds UNNotificationRequest; handles action responses
    NudgeContent.swift           title/body/actions for one nudge
  Away/
    AwayPromptPanel.swift        NSPanel host
    AwayPromptView.swift         break / call+who / other
  Recap/
    RecapView.swift              HSplit: timeline | stack
    TimelineView.swift           vertical, colored by client; meetings/away/logged overlays
    TimelineLane.swift           one stacked lane (sessions, meetings, away, logged)
    SuggestionStackView.swift    confidence-sorted cards + pools + questions
    SuggestionCardView.swift     the card in PLAN §8 "anatomy"
    PoolsSectionView.swift       rolled-up micro-work
    ResolutionQuestionsView.swift "which client is …?" at the bottom
  Dashboard/
    DashboardView.swift          weekly metrics + AI overhead panel
    MetricTileView.swift         one number, no target
    ObservedVsLoggedChartView.swift
    AIOverheadPanelView.swift    from ai_calls; CSV export button
  Settings/
    SettingsView.swift           TabView of the panes below
    Settings*Pane.swift          Accounts, Capture, Suggestions, Recap & Nudges,
                                 Sensitivity, Retention, AI & Budget, Advanced
  ViewModels/                    @MainActor @Observable, one per surface
  ReadModels/                    protocols the surface reads through (see §3)
  Formatting/                    duration, confidence-dots, client-color helpers
```

View models are `@MainActor @Observable` (Swift 6 Observation) and depend only on the
read-model / action protocols in §3 — never on `TidyStore` types directly, so previews and
tests inject fakes.

```swift
@MainActor @Observable
final class MenuBarViewModel {
    private let reading: TodaySummaryReading
    private let capture: CaptureControlling
    private(set) var summary: TodaySummary = .empty
    var icon: MenuBarIcon { MenuBarIcon(captureState: capture.state, attention: summary.attention) }

    init(reading: TodaySummaryReading, capture: CaptureControlling) {
        self.reading = reading; self.capture = capture
    }
    func refresh() async { summary = await reading.today() }
    func togglePause() { capture.setPaused(!capture.state.isPaused) }
}
```

---

## 3. The read-model & action seam

The surface talks to the rest of the app through a handful of protocols. Backed by
`TidyStore` DAOs (and `TidySuggest` for anything computed), they keep the surface
presentation-only and unit-testable with in-memory GRDB.

| Protocol | Reads / does | Backed by |
|---|---|---|
| `TodaySummaryReading` | today's observed vs logged, pending suggestion count, attention flags | `daily_rollups`, `sessions`, `pd_time_entries`, `suggestions` |
| `RecapReading` | timeline items + suggestion cards + pools + open questions for a `day` | `sessions`, `meetings`, `away_gaps`, `pd_time_entries`, `suggestions`, `pools`, `resolution_questions` |
| `DashboardReading` | weekly rollups + AI-overhead aggregates | `daily_rollups`, `sessions`, `ai_calls` |
| `SuggestionActions` | log / edit / reassign / toss a suggestion | writes `suggestions.status` + a `decisions` row |
| `ResolutionAnswering` | answer / dismiss a `resolution_questions` row | writes `entity_signals` (`user_confirmed`) + `resolution_questions` (via `TidyUnderstand`) |
| `AwayResolving` | turn an `away_gaps` row into a suggestion or discard it | writes `away_gaps` + maybe a `suggestions` row |
| `NudgeOutcomeRecording` | record accepted/snoozed/dismissed/ignored | writes `nudges.outcome`, `responded_at` |
| `NudgeEvaluating` | is a nudge eligible right now? (policy, §5) | reads `sessions`, `pd_time_entries`, `calendar_events`/meeting state, `nudges`, `config` |
| `CaptureControlling` | pause / resume capture; current state | flips a runtime flag in `TidyCapture` |
| `ConfigEditing` / `SecretStore` | read + persist `config.json`; write tokens to Keychain | `TidyCore.Config`, Keychain (guardrail [G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)) |

`NudgeEvaluating` and the gap-analysis behind `RecapReading` are the province of `TidySuggest`
(it already gap-analyzes against `pd_time_entries` — see
[suggestion-engine.md](suggestion-engine.md)). The surface consumes the verdict; it does not
recompute attribution.

---

## 4. Menu bar

### 4.1 Icon states

The icon is the app's ground-truth status indicator (guardrail
[G8](../guardrails.md#g8--one-process-no-background-daemons-v1)): if it is absent, capture is
off because the app is not running.

| State | When | Symbol (⚠️ Build-time check: final SF Symbols are a design choice) | Badge |
|---|---|---|---|
| **capturing** | app watcher running, no problems | `record.circle` / template menu-bar glyph | pending-count dot if `> 0` |
| **paused** | user paused capture from the popover | `pause.circle` | — |
| **attention** | needs a human: see below | `exclamationmark.triangle.fill` | red |

`attention` fires on any of: a tripped budget cap → **local-only** mode (guardrail
[G5](../guardrails.md#g5--every-cloud-ai-call-is-metered-and-capped)); a dropped
Accessibility/Automation grant (surfaced by `doctor`, see
[../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md)); an
**unreconciled day** queued for morning catch-up (§7.4); or a persistent ingest sync error
(`sync_state.last_error`). The popover explains which and links the fix.

```swift
enum MenuBarIcon {
    case capturing(pending: Int), paused, attention(reason: AttentionReason)

    init(captureState: CaptureState, attention: AttentionReason?) {
        if let reason = attention { self = .attention(reason: reason) }
        else if captureState.isPaused { self = .paused }
        else { self = .capturing(pending: captureState.pendingCount) }
    }
    var symbolName: String { … }
}
```

### 4.2 Popover (`.menuBarExtraStyle(.window)`)

A compact SwiftUI view — not the recap. Contents:

- **Today so far** — observed vs logged, as a two-segment bar plus `2h15m observed ·
  1h00m logged`. Numbers are today's `daily_rollups` row (recomputed live from `sessions`
  and `pd_time_entries` if the rollup is stale).
- **Pending suggestions** — count of `suggestions` for today with `status = 'pending'`;
  tap opens the recap scrolled to the stack.
- **Pause / Resume capture** — toggles `CaptureControlling`; icon reflects it immediately.
- **Recap…** · **Stats…** · **Settings…** · **Doctor…** · **Quit**.
  Recap and Stats are two tabs of ONE window (`MainWindow`); the menu item chooses the tab, and
  choosing the other one on an already-open window switches tabs rather than opening a second
  window. "Dashboard" was renamed to **Stats** — the old name described a place in the app,
  which only helps someone who already knows the app.
- When `attention`, a one-line banner with a **Fix** button (opens Settings/`doctor`).

```sql
-- today's observed vs logged  (:day_start/:day_end are epoch bounds of the local day;
--  :self = pd_people.id where is_self = 1; :today = 'YYYY-MM-DD')
SELECT COALESCE(SUM(duration_seconds), 0) AS observed_seconds
FROM   sessions
WHERE  started_at >= :day_start AND started_at < :day_end;

SELECT COALESCE(SUM(time_minutes), 0) AS logged_minutes
FROM   pd_time_entries
WHERE  person_id = :self AND date = :today;

SELECT COUNT(*) AS pending
FROM   suggestions
WHERE  day = :today AND status = 'pending';
```

---

## 5. Nudges

A nudge is a rate-limited, meeting-aware live notification fired when a **sustained block
classifies confidently to one client and nothing is logged there yet**. Config lives under
`nudges.*` in [../../config.example.json](../../config.example.json). Ignoring a nudge costs
nothing — everything it would have said still waits in the recap.

### 5.1 Fire conditions (all must hold)

Evaluated by `NudgeEvaluating` (in `TidySuggest`), presented by `TidySurface`:

1. `nudges.enabled == true`.
2. A `sessions` block on **one** `client_id`, still open or just closed, with
   `duration_seconds ≥ nudges.sustained_block_minutes × 60` (default 25 min) and
   `confidence ≥ nudges.confidence_threshold` (default 0.7).
3. **Nothing logged there yet** — no `pd_time_entries` for `:self`, `:today` whose
   `task_id`/`project_id` resolve to that client (the gap-analysis check).
4. **Not in a meeting and not quiet hours** — no `calendar_events` covering `now` (and no
   inferred meeting state), and `now` outside `nudges.quiet_hours` (default 18:00–09:00).
5. **Under the daily cap** — `COUNT(nudges WHERE fired_at in today) < nudges.daily_cap`
   (default 5).
6. **Not suppressed by learning** — this `context_key` hasn't earned a raised threshold from
   repeated dismissals (§5.3).

```sql
-- how many nudges already fired today, and whether this context is being dismissed a lot
SELECT COUNT(*) AS fired_today
FROM   nudges
WHERE  fired_at >= :day_start AND fired_at < :day_end;

SELECT SUM(outcome = 'dismissed') AS dismissals, COUNT(*) AS shown
FROM   nudges
WHERE  context_key = :context_key AND fired_at >= :since;   -- e.g. trailing 14 days
```

### 5.2 Presentation & outcomes

Delivered via `UNUserNotificationCenter` with two actions. On fire, insert a `nudges` row
(`fired_at`, `context_key`, `client_id`, `session_id`, and `suggestion_id` once the pending
suggestion exists); on response, update `outcome` + `responded_at`.

```swift
let content = UNMutableNotificationContent()
content.title = "Log time for \(clientName)?"
content.body  = "About \(minutes)m on \(contextLabel), nothing logged yet."
content.categoryIdentifier = "TIDY_NUDGE"          // actions: ACCEPT, SNOOZE
// UNNotificationAction(identifier: "ACCEPT", title: "Log it & copy note", options: [])
// UNNotificationAction(identifier: "SNOOZE", title: "Later",             options: [])
```

| Action | `nudges.outcome` | Effect |
|---|---|---|
| **Accept** ("Log it & copy note") | `accepted` | marks the linked `suggestions.status = 'logged'`, writes a `decisions` (`action='log'`), and **copies the note to the clipboard** (`NSPasteboard`) so the user pastes into Productive |
| **Snooze** ("Later") | `snoozed` | dismisses the toast; the suggestion stays `pending` for the recap |
| Swiped away / cleared | `dismissed` | feeds §5.3 |
| Never interacted, expired | `ignored` | no penalty |

"Accept" copies but does **not** write to Productive (guardrail
[G1](../guardrails.md#g1--v1-never-writes-to-productive)) — the human still pastes.

### 5.3 Learning from dismissals

Repeated `dismissed` outcomes for a `context_key` raise that context's effective nudge
threshold (a longer required block and/or a temporary cooldown) so the app stops poking where
it isn't wanted. This is a read over the `nudges` table (§5.1 query) applied as a multiplier on
`sustained_block_minutes`; the durable "learn a mapping" work stays in the
[learning loop](understand-layer.md). Phase-6 acceptance requires nudges to stay under the
daily cap and stop firing on dismissed contexts.

---

## 6. Away prompt

On return from an `away_gaps` interval (idle/lock/sleep, `cause` already recorded by
`TidyCapture`), a small floating `NSPanel` asks what the gap was. This is where unrecorded
phone calls get rescued.

> **Away 47 min** — break, a call, or something else?
> [ Break ] [ Call… ] [ Other… ]

| Choice | Writes to `away_gaps` | Becomes |
|---|---|---|
| **Break** | `attribution = 'break'`, `resolved_at = now` | nothing — discarded from suggestions |
| **Call + who/which client** | `attribution = 'call'`, `client_id`/`project_id`, optional `note` | a `suggestions` row (`kind = 'away'`, `source_refs_json = {"away_id": …}`) via `AwayResolving` |
| **Other** (type a word) | `attribution = 'other'`, `note = <word>` | classified from that word; if it resolves to a client, a suggestion, else queued to recap |

The "Call…" path shows a client picker sourced from `pd_companies` (recent/likely first). If
the user dismisses the panel without answering, the gap stays unresolved and **queues into the
recap** (rendered as an away lane the user can still attribute there). No away answer ever
reaches the network.

```swift
@MainActor @Observable
final class AwayPromptViewModel {
    let gap: AwayGap
    private let resolver: AwayResolving
    func choose(_ choice: AwayChoice) async {
        switch choice {
        case .break_:            await resolver.discard(gap)
        case .call(let client, let note): await resolver.asCall(gap, client: client, note: note)
        case .other(let word):   await resolver.asOther(gap, word: word)
        }
    }
    func dismiss() { /* leave unresolved → surfaces in recap */ }
}
```

---

## 7. End-of-day recap window

A real window (never the cramped popover): **left = the day as a vertical timeline; right =
the suggestion stack.** Work the stack top to bottom, copy-paste into Productive as you go.
**Target: under five minutes on a normal day** ([../../PLAN.md](../../PLAN.md) §9). Built in
Phase 5 ([../phases/phase-5-recap-rules.md](../phases/phase-5-recap-rules.md)); the AI-derived
rationale/notes richen it in Phase 6.

```
┌─ Recap — Thu Jul 23 ──────────────────────────────────────────────────────────┐
│  TIMELINE (left)                    │  SUGGESTIONS (right, by confidence)        │
│  09:00 ▓ Client A — EN admin        │  ┌──────────────────────────────────────┐  │
│  09:40 ▓ Client A (already logged)  │  │ Client A › Donate revamp › Build page │  │
│  10:15 ▒ away 20m (unresolved) ⚠    │  │ 1h15m · ●●●○ · matched EN 'clienta'   │  │
│  10:35 ▓ Client B — staging review  │  │ Note: … [Copy note][Copy all][Open]   │  │
│  11:00 ██ Meeting — Weekly sync      │  │ [Log it ✓][Edit][Reassign][Toss]      │  │
│  12:00 ▓ Internal — inbox           │  └──────────────────────────────────────┘  │
│  …                                  │  … more cards …                            │
│                                     │  ── Pools ───────────────────────────────  │
│  legend: ▓ client color · ██ meeting│  Client B · Slack help ·  30m (rolled up)  │
│          ▒ away · hatched = logged  │  ── Questions ───────────────────────────  │
│                                     │  Which client is staging.example.org? [▾]  │
└─────────────────────────────────────┴────────────────────────────────────────────┘
```

### 7.1 Left — timeline

A vertical time axis for the `day`, with four overlaid lanes:

- **Sessions**, colored **by client** (`sessions.client_id` → a stable color; unclassified =
  neutral gray). Height ∝ `duration_seconds`. Tapping a block highlights the suggestion(s)
  it feeds (via `source_refs_json`).
- **Meetings** (`meetings`, `duration_seconds` = recording span) drawn as their own blocks so
  the day's shape reads at a glance.
- **Away gaps** (`away_gaps`) as translucent bands; unresolved ones carry a ⚠ and are tappable
  to attribute inline (reusing §6's picker).
- **Already-logged** entries (`pd_time_entries` for `:self`, `:today`) drawn as a hatched
  overlay so you *see* what's already in Productive and don't double-log — this is the visual
  side of gap analysis.

```sql
-- timeline blocks for the day
SELECT id, kind, started_at, ended_at, duration_seconds, title, client_id, confidence
FROM   sessions
WHERE  started_at >= :day_start AND started_at < :day_end
ORDER  BY started_at;

SELECT id, title, recording_start, recording_end, duration_seconds
FROM   meetings
WHERE  COALESCE(recording_start, scheduled_start) >= :day_start
  AND  COALESCE(recording_start, scheduled_start) <  :day_end;

SELECT id, started_at, ended_at, duration_seconds, cause, attribution, resolved_at
FROM   away_gaps
WHERE  started_at >= :day_start AND started_at < :day_end;

-- already-logged overlay
SELECT id, task_id, project_id, time_minutes, note
FROM   pd_time_entries
WHERE  person_id = :self AND date = :today;
```

Client color: assign deterministically from `client_id` (hash → curated palette) so a client
keeps the same hue across the timeline, dashboard, and future sessions. Keep the palette
colorblind-safe and give each block a text label — color is never the only signal.

### 7.2 Right — suggestion stack

`suggestions` for the day, `status = 'pending'`, **ordered by `confidence` descending** (ties
by `minutes` descending). Each card is the anatomy from [../../PLAN.md](../../PLAN.md) §8 /
[suggestion-engine.md](suggestion-engine.md):

- **Client › Project › Task** (or *propose new task: …* for `kind='new_task'`, using
  `proposed_task_title`/`proposed_task_description`).
- **`minutes` · confidence dots · "why" line** — `minutes` formatted `1h15m`; confidence →
  `●●●○` (4-dot scale, see §9); `is_rounded_up` shows a "rounded" tag; `rationale` is the
  why-line ("matched EN account 'clienta'", "transcript segment 00:12:40–00:26:55").
- **Note** — editable one-to-two sentences (`note`).
- **Buttons** — `[Copy note] [Copy all] [Open task in Productive] [Log it ✓] [Edit]
  [Reassign] [Toss]`.

| Button | `suggestions.status` | `decisions.action` | Notes |
|---|---|---|---|
| Copy note | — | — | `NSPasteboard` ← `note` |
| Copy all | — | — | `NSPasteboard` ← duration + note together |
| Open task in Productive | — | — | `NSWorkspace.open(deep_link)` — opens URL, **no API call** |
| Log it ✓ | `logged` | `log` | local mark only (guardrail G1); feeds gap analysis & metrics |
| Edit | `edited` | `edit` | before/after snapshots into `decisions.before_json/after_json` |
| Reassign | `reassigned` | `reassign` | new client/project/task → strengthens `entity_signals` via learning loop |
| Toss | `tossed` | `toss` | dismissed |

```sql
SELECT * FROM suggestions
WHERE  day = :today AND status = 'pending'
ORDER  BY confidence DESC, minutes DESC;
```

Every action writes a `decisions` row through `SuggestionActions`; that table is the learning
loop's training signal ([understand-layer.md](understand-layer.md)). The surface itself never
promotes rules — it just records the decision.

### 7.3 Bottom of the stack — pools & questions

- **Pools** (`pools WHERE day = :today AND status IN ('open','rolled_up')`) render as
  rolled-up micro-work cards with the itemized `items_json` blurbs ("Slack: helped Nick debug
  ENgrid selector; reviewed staging link; …"). Accepting a pool behaves like a suggestion.
- **Resolution questions** (`resolution_questions WHERE status = 'open'`) sit at the very
  bottom — one row each ("Which client is `staging.example.org`?") with a client/project
  picker. Answering writes an `entity_signals` row (`provenance='user_confirmed'`, which
  **outranks inferred**) and sets `status='answered'` via `ResolutionAnswering`; "Not now"
  sets `dismissed`. Answer once, it's a rule forever.

```sql
SELECT * FROM pools
WHERE  day = :today AND status IN ('open', 'rolled_up')
ORDER  BY accumulated_seconds DESC;

SELECT id, question, signal_type, signal_value
FROM   resolution_questions
WHERE  status = 'open'
ORDER  BY created_at;
```

### 7.4 Timing & morning catch-up

- Fires at `recap.time` (default `17:00`, in `organization.timezone`). The app schedules a
  local timer that calls `openWindow(id: WindowID.recap)` at that wall-clock time.
- A day is **reconciled** when its pending suggestions are all resolved (logged/edited/
  reassigned/tossed). Unreconciled days queue.
- **Morning catch-up** (`recap.morning_catchup == true`): on the first activity next morning,
  if the prior day (or any queued day) is unreconciled, open the recap for the **oldest**
  unreconciled day. The menu bar shows `attention` until the queue drains.

```swift
// oldest unreconciled day (drives morning catch-up + the attention badge)
SELECT day FROM suggestions
WHERE  status IN ('pending','snoozed')
GROUP  BY day ORDER BY day ASC LIMIT 1;
```

⚠️ Build-time check: `MenuBarExtra` window-style focus behavior and `openWindow` from a
background timer — verify the recap window activates correctly (and comes to front on morning
catch-up) on the installed macOS version.

---

## 8. Stats (the tab formerly called Dashboard)

Weekly **metrics, no targets** (a deliberate product stance — see
[../../PLAN.md](../../PLAN.md) §9): four numbers, one small chart, plus the AI-overhead panel.
Local only; nothing here calls the network.

### 8.1 The four numbers + chart

Sourced from `daily_rollups` over the current week (Mon–Sun in `organization.timezone`):

| Tile | Source | Definition |
|---|---|---|
| **Observed vs logged** | `SUM(observed_seconds)` vs `SUM(logged_minutes)` | hours the app saw vs hours in Productive |
| **Billable vs internal** | `SUM(billable_minutes)` vs `SUM(internal_minutes)` | the split (donut/stacked bar) |
| **Per-client totals** | `per_client_json` merged across days | ranked client hours for the week |
| **Capture health** | avg `capture_health` (= `attributed_seconds / observed_seconds`) | % of active time attributed |

```sql
SELECT day, observed_seconds, attributed_seconds, logged_minutes,
       billable_minutes, internal_minutes, capture_health, per_client_json, ai_cost_usd
FROM   daily_rollups
WHERE  day >= :week_start AND day <= :week_end
ORDER  BY day;
```

Tiles render as `MetricTileView` — a number and a label, **no goal line, no red/green, no
"you're behind."** The one chart is observed-vs-logged across the week.

### 8.2 AI overhead panel (from `ai_calls`)

The overhead accounting from [../../PLAN.md](../../PLAN.md) §7. Read-only over `ai_calls`
(guardrail [G5](../guardrails.md#g5--every-cloud-ai-call-is-metered-and-capped) guarantees
every cloud call is here):

- **Month-to-date spend** — `SUM(cost_usd)` since the 1st.
- **Cost by job type** — grouped by `job_type`.
- **Escalation rate** — share of economy-tier calls that escalated to Claude (`is the cheap
  tier earning its keep?`).
- **On-device / free share** — the share of classifications resolved without cloud spend;
  derived from `sessions.produced_by_rung` (rungs 1–2 free, rung 3 on-device) with the Apple
  provider count from `ai_calls` for cross-check.

```sql
-- month-to-date spend and cost by job type
SELECT job_type, provider, model,
       COUNT(*)          AS calls,
       SUM(input_tokens) AS in_tok,
       SUM(output_tokens) AS out_tok,
       SUM(cost_usd)     AS cost_usd
FROM   ai_calls
WHERE  occurred_at >= :month_start
GROUP  BY job_type, provider, model
ORDER  BY cost_usd DESC;

-- escalation rate of the economy tier
SELECT
  SUM(outcome = 'escalated') * 1.0 / NULLIF(COUNT(*), 0) AS escalation_rate
FROM   ai_calls
WHERE  provider = 'fireworks' AND occurred_at >= :month_start;

-- free / on-device share of the week's classifications
SELECT produced_by_rung, COUNT(*) AS n
FROM   sessions
WHERE  classified_at >= :week_start_epoch
GROUP  BY produced_by_rung;   -- rung 1–2 free, 3 on-device, 4–5 cloud
```

**CSV export** — a `[Export CSV]` button writes the `ai_calls` ledger via `NSSavePanel` to a
user-chosen local file, for internal overhead accounting. One row per call:

```csv
occurred_at,job_type,provider,model,input_tokens,output_tokens,cost_usd,latency_ms,outcome,request_ref
2026-07-23T14:05:11Z,transcript_split,fireworks,accounts/fireworks/models/kimi-k2p6,48210,1875,0.0533,4120,ok,meeting:abc123
2026-07-23T14:06:02Z,escalation,anthropic,claude-opus-4-8,52011,940,,2210,ok,meeting:abc123
```

The export never contains secrets (guardrail
[G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)); `cost_usd` may be blank when a
provider price is still `null` in the config price table. ⚠️ Build-time check: the local ISO
timestamp format and whether to export epoch vs. ISO — pick one and document it in Settings.

---

## 9. Formatting helpers

Shared so numbers read identically everywhere.

- **Duration** — seconds/minutes → `1h15m`, `45m`, `2h`. Suggestions store `minutes` already
  rounded to `suggestions.increment_minutes`; the timeline uses raw `duration_seconds`.
- **Confidence dots** — `confidence` (REAL 0–1) → four-dot scale: `≥0.9 ●●●●`, `≥0.75 ●●●○`,
  `≥0.5 ●●○○`, `≥0.25 ●○○○`, else `○○○○`. Always paired with a tooltip of the numeric value +
  `produced_by_rung` label ("rung 4 · Fireworks").
- **Client color** — deterministic `client_id → palette index`; colorblind-safe palette; color
  is decoration, the text label is authoritative.

---

## 10. Settings — every knob in `config.example.json`

Settings is the editor for [../../config.example.json](../../config.example.json). **Non-secret
values go to `config.json` via `ConfigEditing`; tokens go to the Keychain via `SecretStore` and
never touch the config file, the DB, logs, or exports (guardrail
[G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)).** Presented as a `TabView`; the
table below maps every pane control to its config path.

| Pane | Control → config path (or Keychain) |
|---|---|
| **Accounts / Tokens** | Keychain-only fields: Productive token, Fathom key, Google OAuth (sign-in), Slack user token, Fireworks key, Anthropic key. Plus `organization.productive_organization_id`, `organization.productive_person_id` (resolved at setup, read-only), `organization.timezone`, `productive.base_url`, `productive.task_deep_link_pattern` (⚠️ Build-time check — capture from web app), `productive.sync_interval_seconds` |
| **Capture** | `capture.browser`; `capture.detection_interval_seconds` (Double — fast change poll, default 1.0); `capture.content_interval_seconds` (Double — slow page-text poll, default 20.0); `capture.separate_chats_by_path` (Bool); `capture.identity_query_keys` ([String], allowlist); `capture.heartbeat_seconds` *(legacy, superseded by the two intervals)*; `capture.idle_threshold_seconds`; `capture.page_text_max_bytes`; **kill switches** per source: `capture.kill_switches.{app_watcher,chrome,calendar,fathom,slack}` (toggles); `sessionization.detour_tolerance_seconds`; `sessionization.min_session_seconds` |
| **Suggestions** | `suggestions.increment_minutes`; `suggestions.round_up_bias` (0–1 slider); `suggestions.standalone_threshold_minutes` |
| **Recap & Nudges** | `recap.time`; `recap.morning_catchup`; `nudges.enabled`; `nudges.sustained_block_minutes`; `nudges.confidence_threshold`; `nudges.daily_cap`; `nudges.quiet_hours.{start,end}` |
| **Sensitivity** | `sensitivity.keywords[]`; `sensitivity.flagged_people[]`; `sensitivity.flagged_terms[]`. Copy: "an empty list never disables the gate" (guardrail [G2](../guardrails.md#g2--the-sensitivity-gate-fails-closed)) |
| **Retention** | `retention_days.{activity_samples,page_snapshots,slack_messages,transcript_utterances}` (guardrail [G9](../guardrails.md#g9--retention-and-privacy-blast-radius)) |
| **AI & Budget** | `ai.enabled`; `ai.on_device.enabled`; **model routing** `ai.routing.{session_batch,transcript_split,note_draft,escalation}` → a key in `ai.models`; the **model table** `ai.models.*` (provider/model/endpoint); the **price table** `ai.prices_usd_per_mtok.*` (input/output, editable when providers reprice); **budget caps** `ai.budget.daily_cap_usd.{fireworks,anthropic}` and `ai.budget.global_daily_cap_usd`; `ai.calibration.{initial_sample_rate,decay_after_days,floor_sample_rate}` |
| **Advanced** | `ingest.fathom.poll_interval_seconds`; `ingest.google_calendar.poll_interval_seconds`; `ingest.slack.{conversation_list_interval_seconds,history_interval_seconds}`; launch-at-login (`SMAppService`, see [overview.md](overview.md#launch-at-login-smappservice)); a link to the `doctor` view (DB/config paths, permission status) |

Editing routing or the model table is **config, not code** — the router reads model slugs from
config so the Fireworks catalog can churn without a rebuild
([classification-ladder.md](classification-ladder.md)). Editing a kill switch, budget cap, or
`ai.enabled` takes effect on the next sync/classification cycle; Settings only writes the file.

⚠️ Build-time check: validate `recap.time` and `nudges.quiet_hours` as `HH:mm`, and reject a
`nudges.confidence_threshold`/`round_up_bias` outside `0…1`, before persisting.

---

## 11. Cross-cutting

- **Theming.** All views honor light/dark via semantic colors; the client palette has
  light/dark variants. No hardcoded backgrounds.
- **Keyboard-first recap.** To hit the <5-minute target: `↑/↓` move the selected card,
  `⌘C` copy note, `⇧⌘C` copy all, `⌘L` log it, `E` edit, `R` reassign, `⌫` toss, `⌘O` open in
  Productive. ⚠️ Build-time check: confirm shortcuts don't collide with system menu-bar-app
  conventions.
- **Accessibility.** Every timeline block and card exposes a VoiceOver label combining client,
  duration, and confidence; color is never the sole carrier of meaning.
- **Empty states.** "Nothing to reconcile — you're caught up" (recap), "No activity captured
  yet" (popover), "No AI calls this month" (overhead panel).
- **Previews & tests.** Because view models depend only on the §3 protocols, every surface has
  SwiftUI previews with fixture data and unit-testable view models over in-memory GRDB — no
  live store, no network ([../build/testing-strategy.md](../build/testing-strategy.md)).

---

## 12. Acceptance criteria (surface slice)

From [../../PLAN.md](../../PLAN.md) §11 (Phases 5–6):

- [ ] Menu bar icon shows capturing/paused/attention correctly; absence of the icon = capture
      off; popover shows today's observed-vs-logged and pending count.
- [ ] A real day reconciles in the recap in **under ~10 min (Phase 5) trending to <5**:
      timeline colored by client with meetings/away/already-logged overlaid; stack sorted by
      confidence; pools and resolution questions at the bottom; copy buttons work; every action
      writes a `decisions` row; **no** write reaches Productive.
- [ ] Unreconciled days queue and the recap re-opens for the oldest one at first activity next
      morning (`recap.morning_catchup`).
- [ ] Nudges fire only under all §5.1 conditions, stay under `nudges.daily_cap`, respect
      meetings/quiet hours, and stop poking dismissed contexts; accept copies the note.
- [ ] Away prompt turns a gap into a suggestion or discards it; unanswered gaps show in the
      recap.
- [ ] The Stats tab shows the four weekly numbers + AI-overhead panel from `ai_calls` with working
      CSV export; **no targets** anywhere.
- [ ] Settings round-trips every knob in `config.example.json`; tokens land in Keychain, never
      in `config.json` (guardrail G6).

## 13. Where to go next

- What the cards contain and how they're built → [suggestion-engine.md](suggestion-engine.md)
- Sessions, entity signals, learning loop, sensitivity gate → [understand-layer.md](understand-layer.md)
- Tables & columns this layer reads/writes → [data-model.md](data-model.md)
- Targets, dependency rules, protocol seams → [module-map.md](module-map.md)
- The invariants every action must respect → [../guardrails.md](../guardrails.md)
- The build order for these surfaces → [../phases/phase-5-recap-rules.md](../phases/phase-5-recap-rules.md),
  [../phases/phase-6-intelligence.md](../phases/phase-6-intelligence.md)
