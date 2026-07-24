# System overview

The five-layer architecture of TidyTime, how the layers map to SwiftPM targets, the
single-process (menu-bar-only) runtime model, the end-to-end data flow (samples → sessions →
classification → suggestions → recap), and the performance bar the capture path must hold.

**Related:** [../README.md](../README.md) (doc index) ·
[../../PLAN.md](../../PLAN.md) §3 (canonical vision) ·
[module-map.md](module-map.md) (targets & dependency rules) ·
[data-model.md](data-model.md) (schema / shared vocabulary) ·
[../guardrails.md](../guardrails.md) (invariants G1–G9)

---

## The five layers

TidyTime is organized into five layers. Each is useful without the ones above it: capture and
ingest bank data even before any understanding exists; the store is inspectable on its own; the
surface renders whatever the layers below have produced. Reproduced from
[../../PLAN.md](../../PLAN.md) §3:

```
┌─────────────────────────────────────────────────────────┐
│ SURFACE   menu bar · nudges · end-of-day recap ·        │
│           away prompts · dashboard · settings           │
├─────────────────────────────────────────────────────────┤
│ UNDERSTAND  sessionization · entity resolution ·        │
│             classification ladder · sensitivity gate ·  │
│             suggestion engine · learning loop           │
├─────────────────────────────────────────────────────────┤
│ STORE     SQLite (GRDB) in ~/Library/Application        │
│           Support/TidyTime · Keychain for tokens        │
├──────────────────────────┬──────────────────────────────┤
│ CAPTURE (local)          │ INGEST (APIs, read-only)     │
│ app & window watcher     │ Productive cache sync        │
│ Chrome adapter + page    │ Fathom meetings/transcripts  │
│ text · idle/away ·       │ Google Calendar events       │
│ meeting state            │ Slack messages               │
└──────────────────────────┴──────────────────────────────┘
```

STORE sits in the middle by design: **CAPTURE, INGEST, UNDERSTAND, and SURFACE never talk to
each other directly — they meet through the database.** That keeps each layer testable a stage
at a time and is the same rule the target dependency graph enforces (see
[module-map.md](module-map.md)).

### Layer → target map

Each layer is one or more SwiftPM library targets in the `TidyKit` package
([module-map.md](module-map.md)). The app target `TidyTimeApp` (in `App/`) is a thin shell that
wires them together.

| Layer | Targets | Writes / owns | Phase it lands |
|---|---|---|---|
| **SURFACE** | `TidySurface` (+ `TidyTimeApp` shell) | reads `TidyStore`/`TidySuggest` view models; no writes to capture data | 0 shell → 5–6 full |
| **UNDERSTAND** | `TidyUnderstand`, `TidyAI`, `TidySuggest` | `sessions`, `entity_signals`, `suggestions`, `decisions`, `pools`, `ai_calls` | 5–6 |
| **STORE** | `TidyStore` (schema/DAOs/retention) + `TidyCore` (models, `Config`, `SecretStore`, `TidyLog`) | the SQLite file + Keychain access | 0 |
| **CAPTURE** | `TidyCapture` | `activity_samples`, `page_snapshots`, `away_gaps` | 1 |
| **INGEST** | `TidyIngest` | `pd_*`, `meetings`, `transcript_utterances`, `calendar_events`, `slack_messages`, `sync_state` | 2–4 |

Layer sub-docs, one per box in the diagram:

- SURFACE → [surface-layer.md](surface-layer.md)
- UNDERSTAND → [understand-layer.md](understand-layer.md),
  [classification-ladder.md](classification-ladder.md),
  [suggestion-engine.md](suggestion-engine.md)
- STORE → [data-model.md](data-model.md)
- CAPTURE → [capture-layer.md](capture-layer.md)
- INGEST → [ingest-layer.md](ingest-layer.md)

## Single-process model (guardrail G8)

**One process runs everything.** All five layers execute inside the single menu-bar app; there
are no helper tools, XPC services, privileged helpers, or `launchd` daemons in v1. See
[../guardrails.md](../guardrails.md) G8.

Why this shape:

- **Simpler to build, debug, and reason about.** One address space, one logger, one lifecycle.
  No IPC surface to secure or serialize across.
- **The menu bar icon is the ground-truth status indicator.** If capture is running, the icon
  is present and shows a capturing/paused/attention state; if the app isn't running, the
  icon's *absence* tells you capture is off. There is no invisible background collector that
  can silently keep running (or silently stop).
- **TCC grants attach to one signed binary.** A single stable-signed app (guardrail G7) is the
  only thing that ever holds Accessibility/Automation permission — no second binary to sign,
  grant, and keep in sync.

The scene is a SwiftUI `MenuBarExtra`; there is no `WindowGroup` dock app. Windows (recap,
dashboard, settings) are opened on demand from the menu bar.

### Launch at login (`SMAppService`)

Launch-at-login uses **`SMAppService`** (`ServiceManagement`), not a bundled login-item helper
or `SMLoginItemSetEnabled`. Registration is `SMAppService.mainApp` — the main app registers
*itself*, so no separate helper target exists (consistent with G8).

```swift
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()     // may surface a Login Items approval prompt
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

Notes for the implementer:

- `register()` is user-toggleable in Settings; default on after first-run setup. The first
  registration can require the user to approve the item under **System Settings → General →
  Login Items**; surface `.requiresApproval` in the `doctor` view rather than failing silently.
- `SMAppService` keys the registration to the app's bundle id + signature (guardrail G7) — an
  unstable signature loses the registration the same way it loses TCC grants.
- ⚠️ Build-time check: exact `SMAppService.Status` handling and the approval-prompt flow —
  verify against the installed macOS version during Phase 0.

## End-to-end data flow

The pipeline is **write-through-store**: every stage persists to SQLite, and the next stage
reads from SQLite rather than receiving objects in memory. A crash or a restart resumes from
whatever is on disk.

```
 CAPTURE (TidyCapture)                INGEST (TidyIngest, read-only)
 app/window switch + 30 s heartbeat   Productive · Fathom · Google Cal · Slack
        │  page text (Chrome)                │  every ~10–15 min, incremental
        ▼                                    ▼
 activity_samples ─┐                 pd_* · meetings · transcript_utterances
 page_snapshots    │                 calendar_events · slack_messages
 away_gaps         │                         │
        └──────────┴───────────┬─────────────┘
                               ▼   STORE (TidyStore / SQLite)
                        ┌──────────────┐
                        │ sessionize   │  TidyUnderstand
                        │ (samples →   │  contiguous context blocks,
                        │  sessions)   │  meetings get their own kind
                        └──────┬───────┘
                               ▼   sessions
                        ┌──────────────┐
                        │ sensitivity  │  G2 fails closed — sensitive
                        │ gate         │  never leaves the device
                        └──────┬───────┘
                               ▼
                        ┌──────────────┐   classification ladder (G4)
                        │ classify     │  1 rules → 2 lexical → 3 on-device
                        │ (rung 1..5)  │  → 4 economy cloud → 5 Claude
                        └──────┬───────┘  every cloud call metered (G5, ai_calls)
                               ▼   sessions.client_id/project_id/task_id + rung + rationale
                        ┌──────────────┐   TidySuggest
                        │ suggest      │  round to 15 min, pool micro-work,
                        │ engine       │  split meetings, gap-analyze vs pd_time_entries
                        └──────┬───────┘
                               ▼   suggestions
                        ┌──────────────┐   TidySurface
                        │ recap /      │  timeline + card stack; nudges live;
                        │ nudge / away │  user acts → decisions (learning loop)
                        └──────────────┘
```

Step by step:

1. **Samples.** The watcher writes an `activity_samples` row on every app/window switch and on
   a 30-second heartbeat; the Chrome adapter attaches `page_snapshots`. Idle/lock/sleep close
   the current block and write `away_gaps`. (See [capture-layer.md](capture-layer.md).)
2. **Ingest, in parallel.** Read-only sync engines mirror Productive, Fathom, Google Calendar,
   and Slack into their tables, tracked by `sync_state` cursors. (See
   [ingest-layer.md](ingest-layer.md).)
3. **Sessions.** Sessionization collapses contiguous samples into `sessions` (kind
   `screen`/`meeting`/`slack`), tolerating brief detours. Meetings are built from Fathom/
   calendar, not screen samples. (See [understand-layer.md](understand-layer.md).)
4. **Sensitivity gate.** Runs before any cloud rung and before note generation; fails closed
   (guardrail G2). Tripped sessions get `is_sensitive = 1`, resolve locally to a generic task,
   and never enter a cloud payload.
5. **Classification.** Each session climbs the ladder only as far as needed and records the
   rung (`sessions.produced_by_rung`) and a human `rationale`. Cloud rungs write `ai_calls`
   and honor budget caps (guardrails G4, G5). (See
   [classification-ladder.md](classification-ladder.md).)
6. **Suggestions.** Classified sessions round to 15-minute increments, pool sub-threshold
   micro-work, split meetings by transcript segment, and gap-analyze against already-logged
   `pd_time_entries` so only missing time is proposed. Output lands in `suggestions`. (See
   [suggestion-engine.md](suggestion-engine.md).)
7. **Recap / nudges / away prompts.** The surface renders the day as a timeline plus a
   confidence-sorted card stack; the user accepts/edits/reassigns/tosses, and every action
   writes a `decisions` row that feeds the learning loop. **v1 never writes to Productive
   (guardrail G1)** — "Log it ✓" marks a suggestion handled locally only. (See
   [surface-layer.md](surface-layer.md).)

Retention (guardrail G9) purges the raw high-volume tables (`activity_samples`,
`page_snapshots`, `slack_messages`, `transcript_utterances`) after the configured window
(default 90 days); the distilled artifacts (`sessions`, `suggestions`, `decisions`,
`daily_rollups`) persist. Purge policy lives in
[data-model.md](data-model.md#retention-phase-1-job-enforced-ongoing--guardrail-g9).

## Performance bar

The capture path runs all day on a laptop, so it must be invisible: **under ~2% average CPU,
no fan spin-up, no perceptible lag** ([../../PLAN.md](../../PLAN.md) §4). The design principles
that keep it there:

| Principle | What it means concretely |
|---|---|
| **Event-driven first** | Foreground changes come from `NSWorkspace` notifications, not polling; sleep/wake/lock come from notifications. No busy loop watches the frontmost app. |
| **One slow heartbeat** | A single 30-second timer emits a heartbeat sample so long uninterrupted focus still records duration. Idle is polled on the same coarse cadence, not continuously. |
| **Batched writes** | Samples/snapshots accumulate and flush in batches inside one WAL transaction rather than one `INSERT` per event, so bursty switching doesn't thrash the disk. |
| **Cheap sampling** | Window title via Accessibility (`AXUIElement`) and Chrome URL/title via Apple Events are lightweight; page-text capture is throttled (on focus + meaningful change), truncated ~4 KB, and content-hashed to skip duplicate stores. |
| **Local-first classification** | Most sessions resolve at rungs 1–2 (rules + lexical), fully local and zero-cost; cloud rungs run in batches off the hot path, not per-sample (guardrail G4). |
| **No background daemon** | All of the above runs in one process (G8); there is no second collector adding baseline load. |

Acceptance target (Phase 1, [../../PLAN.md](../../PLAN.md) §11): a full workday reads back as a
coherent session timeline in the `doctor` view — including page-text snapshots — with CPU
staying quiet and no gaps across sleep/lock. ⚠️ Build-time check: measure sustained average CPU
with Instruments/`powermetrics` on the target M2-or-newer hardware and confirm it sits under
~2%; tune heartbeat cadence and batch size if not.

## Where to go next

- Building capture → [capture-layer.md](capture-layer.md)
- Building ingest → [ingest-layer.md](ingest-layer.md)
- Building understanding/classification → [understand-layer.md](understand-layer.md),
  [classification-ladder.md](classification-ladder.md)
- Building suggestions → [suggestion-engine.md](suggestion-engine.md)
- Building the UI → [surface-layer.md](surface-layer.md)
- Targets, dependency rules, protocol seams → [module-map.md](module-map.md)
- The invariants every layer must respect → [../guardrails.md](../guardrails.md)
