# Suggestion engine (TidySuggest)

Turns a day's classified `sessions`, `meetings`, and `away_gaps` into rounded, deduplicated,
copy-ready `suggestions` — grouping by task/project, pooling micro-work, splitting meetings by
client, reconciling against what's already logged, and proposing new tasks. Implements PLAN §8.

**Status:** canonical for the suggestion build (rounding, pools, splits, gap analysis, lifecycle) ·
**Target:** `TidySuggest` · **Phases:** 5 (rules/lexical inputs) → 6 (AI-assisted splits/notes) ·
**Last reviewed:** 2026-07-23

Related: [../README.md](../README.md) (doc index) · [../../PLAN.md](../../PLAN.md) §8 ·
[data-model.md](data-model.md) (the `suggestions`/`pools`/`decisions` columns) ·
[classification-ladder.md](classification-ladder.md) (where attribution + splits come from) ·
[surface-layer.md](surface-layer.md) (the recap that renders these cards) ·
[../guardrails.md](../guardrails.md) (G1 read-only, G2 sensitivity, G4 local-first).

---

## 1. Where this runs and what it consumes

`TidySuggest` is a pure transform layer: it reads distilled rows from `TidyStore`, may call the
`TidyAI` router (rung 4/5) for transcript splitting and note drafting, and writes `suggestions`,
`pools`, and (on user action) `decisions`. It never touches the network directly and **never
writes to Productive** — "Log it ✓" is a local status change only (guardrail
[G1](../guardrails.md#g1--v1-never-writes-to-productive)). See target boundaries in
[module-map.md](module-map.md).

| Reads (already classified/ingested) | Writes |
|---|---|
| `sessions` (attribution resolved: `client_id`/`project_id`/`task_id`, `confidence`, `produced_by_rung`, `is_sensitive`) | `suggestions` |
| `meetings` + `transcript_utterances` (Fathom durations + speaker-timestamped text) | `pools` |
| `away_gaps` (with `attribution` from the away prompt) | `decisions` (on user action) |
| `pd_time_entries` (what's already logged — gap analysis) | updates `sessions.*`? **no** — read-only here |
| `pd_tasks` / `pd_projects` / `pd_companies` (names, `project_type_id`, deep links) | |

Trigger points:

- **At recap** (config `recap.time`, default `17:00` local): full rebuild for the day — the
  authoritative pass. Also the pass that force-rolls every open `pool` regardless of size.
- **Incrementally** (Phase 6, for nudges): when a single session crosses the nudge block size,
  build just that one candidate suggestion so a nudge can fire; the recap rebuild supersedes it.

Everything a nudge would surface still lands in the recap, so the incremental path is an
optimization, never the source of truth.

## 2. Pipeline (order of operations)

```
classified sessions + meetings + away_gaps for `day`
        │
        ├─(a) meeting sessions ──► split by client ─────────► meeting_segment suggestions
        │                          (Fathom recording span,
        │                           transcript segments)
        │
        ├─(b) screen/slack sessions ─► group by task ?? project ─► sum raw_seconds
        │           │
        │           ├─ group sum ≥ standalone_threshold ─► standalone (kind='session')
        │           └─ group sum <  standalone_threshold ─► feed pools (per project/day)
        │
        ├─(c) pools ─► roll up at ≥ threshold during day, or all open pools at recap
        │                                                 ─► kind='pool' (itemized note)
        │
        ├─(d) away_gaps attributed 'call' ─────────────────► kind='away'
        │
        ├─(e) groups w/ client+project but no matching task ─► kind='new_task' (proposed_*)
        │
        ▼
   ROUND every candidate (raw_seconds → minutes, set is_rounded_up)   [§4]
        ▼
   GAP ANALYSIS vs pd_time_entries: suppress reconciled / suggest delta / flag disagreement [§7]
        ▼
   persist `suggestions` (status='pending'); link pools.suggestion_id; carry is_sensitive
        ▼
   recap renders cards; user actions write `decisions` + advance `status`   [§9–10]
```

Steps (a)–(e) are mutually exclusive per unit of time: a session counted in a standalone group
is never also pooled; a meeting's minutes come only from its split, never from screen samples
captured concurrently (those are labeled in-meeting context upstream). No double-suggesting.

## 3. Grouping sessions into standalone suggestions

Non-meeting sessions for the day group by the **most specific resolved level**, per PLAN §8
("group by task (or by project when no task matched)"):

```
groupKey = task_id ?? project_id ?? client_id     // fully unresolved → not grouped (see below)
```

For each group: sum `sessions.duration_seconds` → `raw_seconds`; carry `client_id`/`project_id`/
`task_id` from the group; `confidence` = min (or weighted mean) of member confidences;
`produced_by_rung` = the highest rung any member needed; `rationale` = the dominant member's
rationale (e.g. `matched EN account 'exampleorg'`); `is_sensitive` = 1 if **any** member is
sensitive (fail closed, [G2](../guardrails.md#g2--the-sensitivity-gate-fails-closed)).

| Group sum (`raw_seconds` / 60) | Outcome |
|---|---|
| ≥ `suggestions.standalone_threshold_minutes` (default **15**) | standalone suggestion, `kind='session'`, `source_refs_json = {"sessions":[…ids]}` |
| < threshold | fragments feed the project's micro-work `pool` for the day (§5) |

`sessions` with no `project_id`/`task_id` but a resolved `client_id` group by `client_id`
(project stays NULL); fully unresolved sessions produce **no** suggestion — they stay on the
timeline and, if driven by a recurring unknown signal, spawn a `resolution_questions` row asked
once in the recap. Attribution itself is upstream in `TidyUnderstand` /
[classification-ladder.md](classification-ladder.md); this layer only aggregates it.

`billable` is inferred from `pd_projects.project_type_id` (client/deliverable `2` → `1`;
internal `1` → `0`), stored on the suggestion and overridable by the user.

## 4. Rounding to 15-minute increments (with round-up bias)

Rounding is applied to **eligible amounts only**: standalone group sums, pool rollups, and each
meeting segment — never to a sub-threshold session on its own (that goes to a pool as raw
seconds). It writes `suggestions.minutes` (rounded) and `suggestions.raw_seconds` (observed,
pre-rounding) and sets `suggestions.is_rounded_up`.

### Config (all in `config.json` under `suggestions` — these are **config keys, not columns**)

| Key | Default | Meaning |
|---|---|---|
| `suggestions.increment_minutes` | `15` | rounding block size |
| `suggestions.round_up_bias` | `0.4` | fraction-of-a-block at which rounding flips **up** |
| `suggestions.standalone_threshold_minutes` | `15` | min real minutes to stand alone (also the pool rollup threshold) |

`round_up_bias` ∈ `[0, 0.5]`: **round up when the fractional position within a block is ≥
`round_up_bias`.** `0.5` == plain nearest rounding; smaller == more generous; `0.0` == always
ceil. The default `0.4` is a *slight* upward tilt — you round up once you are ≥40% into a block,
versus nearest's 50%.

> ⚠️ Note the naming: `suggestions.round_up_bias` is a **config key**. The only rounding-related
> *column* in [data-model.md](data-model.md) is `suggestions.is_rounded_up` (0/1). Do not look
> for a `round_up_bias` column — it does not exist.

### Algorithm

```swift
struct RoundedDuration { let minutes: Int; let isRoundedUp: Bool }

/// Round observed seconds to `incrementMinutes` blocks with an upward bias.
/// - roundUpBias: 0.5 == nearest, <0.5 == up-biased, 0.0 == ceil (clamped to [0, 0.5]).
/// - floorToIncrement: eligible time (segment / pool@recap / grouped session) never rounds to 0.
func roundMinutes(rawSeconds: Int,
                  incrementMinutes: Int = 15,      // suggestions.increment_minutes
                  roundUpBias: Double = 0.4,       // suggestions.round_up_bias
                  floorToIncrement: Bool = true) -> RoundedDuration {
    precondition(rawSeconds >= 0)
    let bias  = min(max(roundUpBias, 0.0), 0.5)
    let inc   = Double(incrementMinutes)
    let raw   = Double(rawSeconds) / 60.0
    let lower = (raw / inc).rounded(.down) * inc          // block at or below
    let frac  = (raw - lower) / inc                        // 0 ..< 1 within the block
    var out   = (frac >= bias) ? lower + inc : lower
    if floorToIncrement, out == 0, rawSeconds > 0 { out = inc }  // never suggest 0 for real time
    let minutes = Int(out)
    return RoundedDuration(minutes: minutes,
                           isRoundedUp: Double(minutes) * 60.0 > Double(rawSeconds))
}
```

`is_rounded_up` is purely factual: **the rounded suggestion grants more time than was observed**
(`minutes*60 > raw_seconds`). It is set on rounds *up* and cleared on rounds *down* or exact.
The recap may visually emphasize only large pads (a UI threshold); the column stays honest.

### Worked examples (`increment_minutes=15`, `round_up_bias=0.4`)

| raw (min) | block floor | frac | nearest (≥0.50) | bias 0.4 (≥0.40) | `minutes` | `is_rounded_up` | note |
|---|---|---|---|---|---|---|---|
| 6.0 | 0 | 0.40 | 0 → floor 15 | **15** | 15 | 1 | meeting seg / small pool at recap |
| 12.0 | 0 | 0.80 | 15 | 15 | 15 | 1 | |
| 15.5 | 15 | 0.03 | 15 | 15 | 15 | 0 | rounds down |
| 21.0 | 15 | 0.40 | 15 | **30** | 30 | 1 | bias flips it up (nearest would stay 15) |
| 22.5 | 15 | 0.50 | 30 | 30 | 30 | 1 | |
| 33.5 | 30 | 0.23 | 30 | 30 | 30 | 0 | rounds down |
| 37.0 | 30 | 0.47 | 45 | 45 | 45 | 1 | |

The bias only changes the result in the `[bias, 0.5)` band of each block (e.g. `21.0` above);
elsewhere it agrees with nearest rounding. Turn the tilt off with `round_up_bias = 0.5`.

## 5. Micro-work pools

Sub-threshold fragments (a 4-minute Slack answer, a 90-second staging check) accumulate **per
project, per day** in `pools` so the little things stop evaporating (PLAN §8). One pool row per
`(day, project_id)`; client-only micro-work pools on `(day, client_id)` with `project_id` NULL.

Accumulation (each time a sub-threshold session is finalized):

```swift
// pools columns: day, client_id, project_id, accumulated_seconds, item_count, items_json, status
pool.accumulated_seconds += session.duration_seconds
pool.item_count          += 1
pool.items_json           = append({ "session_id": s.id,
                                     "seconds":    s.duration_seconds,
                                     "blurb":      blurb(s) })   // short local/AI label
pool.updated_at           = now
```

`blurb(s)` is a compact human label — local template in Phase 5 (`"Slack #client-x: replied to
timeline Q"`, `"reviewed staging link"`), AI-drafted `note_draft` in Phase 6 (still post-gate).

Rollup — a pool becomes exactly **one** `kind='pool'` suggestion when either:

1. `accumulated_seconds ≥ standalone_threshold_minutes * 60` (crosses 15 min during the day), or
2. it is still `open` at recap (any size — even a 3-minute pool is surfaced, floored up to one
   increment so it isn't lost).

On rollup: round `accumulated_seconds` (§4) → `minutes`/`raw_seconds`/`is_rounded_up`; assemble
the note by joining `items_json[].blurb`; set `source_refs_json = {"pool_id": <id>}`; set
`pools.status = 'rolled_up'` then `'suggested'` and `pools.suggestion_id = <new id>`.

Example rolled-up note (PLAN §8):

> Slack: helped Nick debug ENgrid selector; reviewed staging link; replied to Sebrinia re: timeline.

`pools` metadata persists past retention; the underlying `slack_messages`/`activity_samples`
purge on schedule ([G9](../guardrails.md#g9--retention-and-privacy-blast-radius)), which is why
the blurb is captured into `items_json` at accumulation time, not recomputed later.

## 6. Meeting splitting

Each meeting becomes one or more `kind='meeting_segment'` suggestions.

**Duration is ground truth from Fathom**, not the calendar slot: use
`meetings.recording_start`/`recording_end` (→ `meetings.duration_seconds`), *not*
`scheduled_start`/`scheduled_end`. A 60-minute calendar block whose recording ran 61 minutes is
a 61-minute meeting here.

The split comes from `transcript_utterances` (speaker-labeled, `start_seconds`/`end_seconds`
offsets from `recording_start`). Rung 4 (`transcript_split`, Fireworks) returns time-bounded,
client-mapped segments; rung 5 (Claude) adjudicates when segments don't reconcile with the
recording (see reconciliation below). Every segment carries its utterance timestamps into
`rationale` and `source_refs_json` so the math is auditable.

Per segment:

- `client_id`/`project_id` from the segment's mapping; internal remainder → the internal
  company/project (`project_type_id = 1`), `billable = 0`.
- `raw_seconds = end_seconds − start_seconds`; round (§4).
- `rationale = "transcript segment 00:15:52–00:21:52 (Client B page-QA)"`.
- `source_refs_json = {"meeting_id":"<id>","segment":{"start_seconds":952,"end_seconds":1312,"utterance_idx":[41,77]}}`.

### Worked 61-minute example → 15 / 15 / 30

Recording `00:00:00`–`01:01:00` (61 min). `round_up_bias = 0.4`.

| Segment | Span | `raw_seconds` | raw min | frac | `minutes` | `is_rounded_up` | `rationale` |
|---|---|---|---|---|---|---|---|
| Client A | 00:00:00–00:15:30 | 930 | 15.5 | 0.03 | **15** | 0 | rounds down |
| Client B | 00:15:30–00:21:30 | 360 | 6.0 | 0.40 | **15** | **1** | rounded up from 6 (bias), flagged |
| Internal ("weekly sync") | 00:21:30–00:55:00 | 2010 | 33.5 | 0.23 | **30** | 0 | rounds down |
| *(unattributed)* | 00:55:00–01:01:00 | 360 | 6.0 | — | — | — | assembly / wrap-up / cross-talk → no suggestion |

Result: **15 (A) + 15 (B) + 30 (internal) = 60 min**, matching PLAN §8. Only Client B is
`is_rounded_up = 1` ("rounded from 6 with your bias, flagged as rounded").

**Reconciliation.** Rounded segment total (60) is compared to `recording` (61); drift `|60−61| =
1 ≤ tolerance` → accept. Segments need **not** sum to the recording: genuinely low-signal time
(joining, goodbyes, off-topic cross-talk) is left unattributed rather than padded onto the
internal bucket. If drift exceeds tolerance (segments that "don't add up"), that is a rung-5
escalation trigger per [classification-ladder.md](classification-ladder.md) — Claude
re-adjudicates before any suggestion is written.

**Unrecorded meetings.** No Fathom recording → fall back to the calendar slot
(`calendar_events.start_at`/`end_at`) as `meetings.duration_seconds`, one whole-meeting segment,
attribution from attendee `email_domain` / title signals (`meeting_invitees`, rung 1–2). Split
is skipped (no transcript to split on).

## 7. Gap analysis (vs. what's already logged)

Before persisting, reconcile the day's candidates against `pd_time_entries` already logged for
the user, so the recap **suggests only what's missing** and flags disagreements instead of
double-suggesting (PLAN §8).

```sql
-- what the user already logged for the day (Productive minutes)
SELECT task_id, project_id, SUM(time_minutes) AS logged_minutes
FROM   pd_time_entries
WHERE  person_id = :self_person_id      -- pd_people.is_self = 1
  AND  date       = :day                -- 'YYYY-MM-DD', local zone
GROUP  BY task_id, project_id;
```

Per candidate group, let `obs = raw_seconds/60` (observed, pre-rounding) and `log = logged
minutes for the same task/project`. Tolerance defaults to one increment
(`increment_minutes`, 15) — an optional `suggestions.gap_tolerance_minutes` may override it
(⚠️ Build-time check: this key is not yet in `config.example.json`).

| Condition | Action |
|---|---|
| `\|obs − log\| ≤ tolerance` | **Reconciled** — suppress; emit no suggestion for this group. |
| `obs − log > tolerance` (under-logged) | Emit a suggestion for the rounded **delta** `(obs − log)`; `rationale` notes the existing entry: `"already logged 60m; observed ~135m — suggesting the missing 75m"`. |
| `log − obs > tolerance` (over-logged) | **Disagreement flag only** — never suggest negative time. Surface on the recap timeline: `"you logged 2h on Task X; I saw about 45m — review?"`. Not persisted as its own row (recomputed at recap; see uncertainties). |

Gap analysis always compares on **raw observed** minutes, not rounded, so rounding bias never
inflates a reconciliation. The disagreement copy lives in the delta suggestion's `rationale`
(under-logged) or is rendered transiently by the recap (over-logged).

## 8. New-task proposals

When a group clearly belongs to a client+project (rung 3/4 attribution agrees with lexical
scores) but matches **no open** `pd_tasks`, emit `kind='new_task'` instead of guessing a task:

| Column | Value |
|---|---|
| `client_id`, `project_id` | resolved client + project |
| `task_id` | `NULL` (task doesn't exist yet) |
| `proposed_task_title` | copy-ready, e.g. `"Donation page — mobile layout QA"` |
| `proposed_task_description` | 1–2 sentences of context, copy-ready |
| `minutes` / `raw_seconds` / `is_rounded_up` | from the group, rounded (§4) |
| `deep_link` | project board URL if derivable, else `NULL` (no task to link yet) |
| `source_refs_json` | `{"sessions":[…ids]}` |

The user creates the task in Productive themselves — **this layer proposes, it never writes**
([G1](../guardrails.md#g1--v1-never-writes-to-productive)). Re-link on next Productive sync
(~15 min): match `proposed_task_title` against newly-synced `pd_tasks` in that project; on match,
set `suggestions.task_id`, populate `deep_link`, and switch `kind` to `'session'`. Until then the
card shows "propose new task: …".

## 9. Suggestion-card anatomy

The recap ([surface-layer.md](surface-layer.md)) renders each `suggestions` row as a card. Field
→ column map:

```
┌──────────────────────────────────────────────────────────────────────┐
│ Client A › Donation Rebuild › Mobile layout QA        [Open task ↗]   │  ← client_id/project_id/task_id names
│  (or "propose new task: Donation page — mobile QA")                    │     · deep_link  · kind='new_task' → proposed_task_title
│ 1h 15m ⤴rounded · ●●●○ · matched EN account 'exampleorg'              │  ← minutes (+is_rounded_up marker) · confidence dots · rationale (+produced_by_rung)
│ Note: Rebuilt the mobile breakpoints and re-ran the donation flow…    │  ← note (editable)
│ [Copy note] [Copy all] [Open task in Productive] [Log it ✓] [Edit]    │
│ [Reassign] [Toss] [Snooze]                                            │  ← actions → decisions + status (§10)
└──────────────────────────────────────────────────────────────────────┘
```

- **Title line:** `client_id`→name › `project_id`→name › `task_id`→title, resolved from the
  `pd_*` cache. `kind='new_task'` renders `proposed_task_title` with a "propose new task" affix.
- **Duration:** `minutes` (formatted `1h 15m`); `is_rounded_up = 1` shows an unobtrusive
  "rounded" marker.
- **Confidence:** `confidence` (0–1) → four filled/empty dots; the "why" line is `rationale`,
  provenance from `produced_by_rung` (1 rule … 5 Claude).
- **Sensitive:** `is_sensitive = 1` → generic task + bland note already applied upstream by the
  gate; the card shows a subtle lock, never the raw content (G2).
- **Copy all:** puts `minutes` + `note` on the clipboard together; **Copy note** just `note`.
- **Open task in Productive:** `deep_link` (`config.productive.task_deep_link_pattern`).

## 10. Status lifecycle + decisions

`suggestions.status` starts `'pending'` and advances on user action; every action also writes one
`decisions` row (the learning-loop training signal). Enum values are exactly those in
[data-model.md](data-model.md).

```
                 ┌──────── snooze ─────────┐  (re-surfaces next recap / morning)
                 ▼                         │
   ┌─────────┐  edit    ┌─────────┐        │
   │ pending │ ───────► │ edited  │ ──log─► │  ┌────────┐
   │(default)│          └─────────┘         └─►│ logged │  (terminal ✓)
   └────┬────┘  reassign ┌──────────┐  log     └────────┘
        │ ─────────────► │reassigned│ ─────────►  ▲
        │                └──────────┘             │
        ├──────────── log ───────────────────────┘
        └──────────── toss ──────────► ┌────────┐
                                       │ tossed │  (terminal ✗)
                                       └────────┘
```

| Card / nudge action | `decisions.action` | resulting `suggestions.status` | Side effect (learning loop) |
|---|---|---|---|
| **Log it ✓** | `log` | `logged` | marks handled **locally only** — no Productive write (G1); feeds gap analysis + `daily_rollups` |
| **Edit** (duration/note) | `edit` | `edited` | `before_json`/`after_json` snapshots; duration edits tune future round-up bias |
| **Reassign** (client/project/task) | `reassign` | `reassigned` | creates/strengthens `entity_signals` (reassign a signal twice → a rule) |
| **Toss** | `toss` | `tossed` | negative signal for that context |
| **Snooze** | `snooze` | `snoozed` | defers to next recap / morning catch-up; re-enters `pending` view |
| Nudge **Accept** (live nudge path) | `accept` | `logged` | copies the note, marks handled; equivalent to Log it ✓ from the popover |

`edited`/`reassigned` are non-terminal — a subsequent **Log it ✓** carries them to `logged`.
`logged` and `tossed` are terminal. Each `decisions` row records `suggestion_id`, `action`, the
`before_json`/`after_json` snapshots, the resolved `client_id`/`project_id`/`task_id` (especially
for `reassign`), and any `note`. Nudge outcomes additionally land in `nudges.outcome`
(Phase 6) — see [surface-layer.md](surface-layer.md).

## 11. Column cheat-sheet (`suggestions` / `pools` / `decisions`)

Quick map of every field this engine writes (full DDL in [data-model.md](data-model.md)):

```
suggestions
  day                        YYYY-MM-DD local (from session started_at's local day)
  kind                       'session' | 'pool' | 'meeting_segment' | 'away' | 'new_task'
  client_id/project_id/task_id  resolved attribution (task NULL for new_task)
  proposed_task_title/description  new_task only, copy-ready
  minutes                    rounded (§4)
  raw_seconds                observed, pre-rounding (gap analysis + audit)
  billable                   inferred from project_type_id (0/1/NULL)
  note                       1–2 sentences, editable; pools = itemized join
  confidence                 0..1 → dots
  produced_by_rung           1..5 (provenance for the "why" line)
  rationale                  human "why" (rule / lexical / "transcript segment …")
  is_rounded_up              1 iff minutes*60 > raw_seconds
  is_sensitive               1 → generic task + bland note (G2)
  deep_link                  Productive task URL (NULL until a new_task re-links)
  status                     'pending'→'logged'|'edited'|'reassigned'|'tossed'|'snoozed'
  source_refs_json           {"sessions":[…]} | {"pool_id":n} | {"meeting_id","segment"} | {"away_id":n}

pools
  day, client_id, project_id
  accumulated_seconds, item_count
  items_json                 [{session_id, seconds, blurb}]
  status                     'open' → 'rolled_up' → 'suggested'
  suggestion_id              set on rollup

decisions
  suggestion_id, action      'accept'|'edit'|'reassign'|'toss'|'log'|'snooze'
  before_json/after_json     snapshots around edit/reassign
  client_id/project_id/task_id, note, created_at
```

## 12. File & function manifest (`Packages/TidyKit/Sources/TidySuggest/`)

| File | Key entry points |
|---|---|
| `SuggestionEngine.swift` | `buildDay(_ day: String) async throws -> [Suggestion]` — orchestrates §2; `buildCandidate(for session:)` for the incremental nudge path |
| `Rounding.swift` | `roundMinutes(rawSeconds:incrementMinutes:roundUpBias:floorToIncrement:) -> RoundedDuration` (§4) |
| `Grouping.swift` | `groupSessions(_:) -> [SessionGroup]` (task ?? project ?? client); `SessionGroup.rawSeconds` |
| `PoolManager.swift` | `accumulate(session:into:)`, `rollup(_ pool:reason:) -> Suggestion`, `rollAllOpen(day:)` |
| `MeetingSplitter.swift` | `split(_ meeting:) async throws -> [MeetingSegment]` (calls `TidyAI` router for `transcript_split`; `reconcile(segments:against:)` drift check) |
| `GapAnalyzer.swift` | `reconcile(candidates:against entries:) -> GapResult` (suppress / delta / flag, §7) |
| `NewTaskProposer.swift` | `propose(for group:) -> Suggestion?`; `relink(on syncedTasks:)` |
| `SuggestionActions.swift` | `apply(_ action:to:) -> Decision` (§10 status transitions + `decisions` write) |

All persistence goes through `TidyStore` DAOs; `MeetingSplitter`/note drafting degrade to
local-only output when the `TidyAI` router is unavailable (budget cap tripped or Apple
Intelligence off) — the engine must still produce suggestions with local rungs
([module-map.md](module-map.md) dependency rules).

## 13. Acceptance criteria

- Grouping: a day's sessions on one task produce exactly one `kind='session'` suggestion whose
  `raw_seconds` equals the summed session seconds; sub-threshold fragments produce none directly.
- Rounding: `roundMinutes` matches the §4 table for `bias ∈ {0.0, 0.4, 0.5}`; `is_rounded_up`
  is set iff `minutes*60 > raw_seconds`; eligible time never rounds to `0`.
- Pools: N sub-threshold sessions on one project yield exactly one `kind='pool'` suggestion with
  `item_count = N`, an itemized note, and `pools.status='suggested'` linked via `suggestion_id`;
  a still-open pool of any size rolls up at recap.
- Meeting split: the 61-min fixture yields **15 / 15 / 30** with only Client B `is_rounded_up=1`,
  each segment carrying utterance timestamps in `source_refs_json`; duration comes from
  `recording_*`, verified by feeding a case where calendar slot ≠ recording span.
- Gap analysis: a group with an existing `pd_time_entries` row within tolerance emits no
  suggestion; an under-logged group emits a rounded delta with the "already logged …" rationale;
  an over-logged group emits a flag and **no** suggestion.
- New-task: `kind='new_task'` sets `proposed_task_title`/`description`, `task_id=NULL`; after a
  sync introduces the matching task, re-link sets `task_id`/`deep_link` and flips `kind`.
- Lifecycle: each action writes one `decisions` row and advances `status` per §10; **no code path
  in `TidySuggest` issues a non-GET request to Productive** (guardrail test, G1).

## 14. Gotchas & invariants

- **Rounding is not conserved across the day.** The sum of rounded `minutes` can exceed observed
  time — that is the point of the bias. Gap analysis and reconciliation always use `raw_seconds`,
  never `minutes`.
- **Mutual exclusivity.** A session is either in a standalone group **or** in a pool **or** part
  of a meeting split — never counted twice. Concurrent screen samples during a meeting are
  in-meeting context (upstream), not separate work.
- **Meeting segments are never pooled** and never re-rounded after the split.
- **`is_sensitive` propagates and fails closed:** any sensitive member makes the group/segment
  sensitive → generic task + bland note; raw content never reaches a card or a cloud payload (G2).
- **`is_rounded_up` is data, not presentation** — the recap decides how loudly to show it.
- **Day assignment:** a suggestion's `day` is the local day of the source's `started_at`
  (`config.organization.timezone`); idle closes sessions, so midnight-spanning sessions are rare
  and, if present, are attributed by start.
- **Units:** our tables are seconds (UTC epoch); `pd_time_entries.time_minutes` is **minutes** —
  convert at the gap-analysis boundary, not inside the engine.
- **"Log it ✓" is local.** It sets `status='logged'` and feeds metrics; the actual Productive
  entry is the user's to make (v1 read-only, G1).
```
