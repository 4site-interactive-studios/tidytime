# Phase 5 — Recap & rules

The first end-to-end "what did I miss today?" — **before any AI**. Classify sessions with the two
local ladder rungs (deterministic rules + lexical matching), turn them into rounded, pooled,
gap-analyzed `suggestions`, and render the recap window (timeline + confidence-sorted card stack
with copy buttons) plus morning catch-up, ask-once resolution questions, and recorded decisions.

**Related:** [doc index](../README.md) · [PLAN.md](../../PLAN.md) §7, §8, §9, §11 ·
[architecture/understand-layer.md](../architecture/understand-layer.md) ·
[architecture/suggestion-engine.md](../architecture/suggestion-engine.md) ·
[architecture/surface-layer.md](../architecture/surface-layer.md) ·
[architecture/data-model.md](../architecture/data-model.md) ·
[phase-4-slack.md](phase-4-slack.md) · [phase-6-intelligence.md](phase-6-intelligence.md)

**Phase:** 5 of 6 · **Targets:** `TidyUnderstand` (rungs 1–2, learning loop), `TidySuggest`
(engine), `TidySurface` (recap) · **Depends on:** Phases 0–4 (all capture + ingest banking data) ·
**Unlocks:** Phase 6 layers cloud AI + nudges on top of a working recap ·
**Status:** build-ready spec · **Last verified:** 2026-07-23

---

## 0. At a glance

| | |
|---|---|
| **Ships** | Rung 1 (rules) + Rung 2 (lexical) classification; full `Sessionizer` for screen sessions; the suggestion engine (15-min rounding + round-up bias, micro-work pools, gap analysis, new-task proposals, template notes); the recap window; morning catch-up; ask-once `resolution_questions`; `decisions` + the rules/examples learning loop |
| **New tables** | `entity_signals`, `pools`, `suggestions`, `decisions`, `resolution_questions`, `daily_rollups` (data-model.md phase map) |
| **Does NOT ship** | Any cloud/on-device AI — **rungs 3–5 are Phase 6** (G4); the sensitivity gate proper (Phase 6, ships with the first cloud call, G2); **per-client meeting splitting via transcript** (rung 4 = Phase 6 — meetings are whole-block here); nudges & the dashboard UI (Phase 6) |
| **Writes to Productive** | **Never** (G1). "Log it ✓" marks a suggestion handled **locally only**; the human copy-pastes into Productive |

### Acceptance criteria (PLAN §11, human-verifiable)

> **Reconcile a real day in under ten minutes, and at least one forgotten billable block from that
> week makes it into Productive because the recap caught it.**

Concretely:

- [ ] Opening the recap for a real workday shows a coherent left-hand **timeline** (screen sessions
      colored by client, meetings at Fathom-true durations, Slack sessions, away gaps, and
      already-logged Productive entries overlaid) and a right-hand **card stack** sorted by
      confidence, with pools and open resolution questions at the bottom.
- [ ] Working the stack top-to-bottom — copy note / copy all, open task in Productive, Log it ✓ —
      takes **under ten minutes** on a normal day.
- [ ] A billable block you would have forgotten (a Slack drive-by, the 15 client minutes inside a
      colleague call, an away-gap phone call) is **surfaced by the recap**, and you paste it into
      Productive. That is the "forgotten billable block reaches Productive" proof.
- [ ] **Gap analysis** means the recap proposes only *missing* time and flags disagreements against
      what's already logged — it does not double-suggest.
- [ ] Answering an ask-once question ("Which client is `staging.example.org`?") makes the next
      same-context session classify at **rung 1** with a `user_confirmed` rationale.
- [ ] No cloud/on-device model is called anywhere in this phase (`ai_calls` stays empty; G4).

---

## 1. Prerequisites & what "before any AI" means

1. **Phases 0–4 are banking data.** Screen `activity_samples`/`page_snapshots`/`away_gaps`
   (Phase 1), the Productive mirror `pd_*` (Phase 2), `meetings`/`transcript_utterances`/
   `calendar_events` (Phase 3), and `slack_messages` (Phase 4) all exist. Phase 5 reads them and
   writes the understand/suggest tables. Capture-first pays off here: weeks of history to classify.
2. **No cloud, no on-device model.** The classification ladder ([classification-ladder.md](../architecture/classification-ladder.md))
   has five rungs; Phase 5 implements **only rungs 1–2**. A session rungs 1–2 can't settle is left
   **unclassified** (`client_id` NULL) and simply shows in the timeline without a confident
   suggestion — Phase 6 adds rungs 3–5 to close the gap. Never call a model in this phase (G4).
3. **Sensitivity gate is Phase 6.** It "ships before or with the first cloud call" (PLAN §11, G2).
   Phase 5 generates **template** notes locally from titles/participants — nothing leaves the
   device — so the gate is not yet load-bearing; sessions/suggestions ship `is_sensitive = 0`.
   (Leave the `is_sensitive` columns and code seams in place for Phase 6.)

---

## 2. Rung 1 — deterministic rules (`entity_signals`)

Rung 1 is the free, fully-local base: a session whose dominant signal already maps to a
client/project in `entity_signals` gets that attribution immediately. Detail lives in
[understand-layer.md §2](../architecture/understand-layer.md#2-entity-resolution--the-client-registry-entity_signals);
Phase 5 builds it.

### 2.1 Bootstrap the registry from Productive (setup)

Seed `entity_signals` from the Productive cache — no capture required
([understand-layer.md §2.2](../architecture/understand-layer.md#22-bootstrap-from-productive-vocabulary-setup--phase-5)):

| Productive source | `signal_type` | `provenance` |
|---|---|---|
| `pd_companies.domain` | `email_domain`, `url_host` | `bootstrapped` |
| `pd_companies.name` tokens | `keyword` | `bootstrapped` |
| `pd_projects.name` tokens | `keyword` (→ `project_id`) | `bootstrapped` |
| `pd_tasks.title` distinctive tokens | `keyword` | `bootstrapped` |

`signal_type` is **exactly** one of the eight values in
[data-model.md](../architecture/data-model.md#understand--suggest-phase-5) /
[understand-layer.md §2.1](../architecture/understand-layer.md#21-signal_type-taxonomy-exact--from-data-modelmd):
`email_domain`, `slack_channel`, `staging_url`, `url_host`, `en_account`, `person_email`,
`keyword`, `meeting_title`. `UNIQUE(signal_type, signal_value)` — re-observation bumps
`hit_count`/`last_seen_at`, never inserts a duplicate.

### 2.2 Matching a session against signals

For each unclassified session, derive its candidate signals from its `context_key` and members,
then look them up:

| Session `kind` | Signals to look up |
|---|---|
| `screen` | `url_host`/`staging_url` from `context_key`; `en_account`/`keyword` from `page_snapshots.text` & window title |
| `meeting` | `email_domain`/`person_email` from `meeting_invitees`; `meeting_title` from `meetings.title` |
| `slack` | `slack_channel` = `source_ref` (conversation id); `person_email`/`email_domain` of participants |

On a match, set `sessions.client_id`/`project_id`, `produced_by_rung = 1`, a human `rationale`
(e.g. `"matched EN account 'exampleorg'"`), and a high `confidence`. Multiple matches that disagree
resolve by **provenance → weight → hit_count**
([understand-layer.md §2.3](../architecture/understand-layer.md#23-provenance-precedence-conflict-resolution)):

```
user_confirmed  >  bootstrapped  >  inferred
```

> **Vocabulary note.** The canonical `provenance` values are `bootstrapped` / `inferred` /
> `user_confirmed` (data-model.md). PLAN/glossary say "learned" — it is a synonym for `inferred`;
> use `inferred` in code (understand-layer.md §2.2 doc-drift note).

### 2.3 Minting inferred signals as capture cross-references

As sessions classify, cross-referencing observables against each other mints new
`provenance = 'inferred'` signals (a Slack channel whose members map to a known client's domain; a
staging host seen alongside a known EN account). These are *guesses* and are outranked by
bootstrapped/user-confirmed. The learning loop (§9) promotes the ones the user confirms.

---

## 3. Rung 2 — lexical matching

When no rule fires, tokenize the session's text and score it against the Productive cache
vocabulary. Rung 2 is still fully local and zero-cost.

- **Inputs:** tokenized window/tab titles, `url` path stems, `page_snapshots.text`, meeting
  `title` + transcript utterance text, Slack `text` — normalized (lowercased, de-punctuated,
  stop-words dropped).
- **Corpus:** `pd_companies.name`, `pd_projects.name`, `pd_tasks.title` (+ `description` tokens),
  each tied to its client/project/task id.
- **Score:** token-overlap / TF-weighted similarity per candidate. Classify only on a **high
  margin** (top candidate clears the runner-up by a configurable gap); **near-ties fall through**.
  In Phase 5 a fall-through has nowhere higher to go, so the session stays **unclassified** (Phase
  6 sends it to rungs 3–5). Record `produced_by_rung = 2`, a `rationale` naming the matched
  task/project token, and a moderate `confidence`.

```swift
// TidyUnderstand/Classifier.swift — rungs 1–2 only in Phase 5.
func classify(_ s: DraftSession) -> Classification {
    if let r = ruleMatch(s)   { return r }        // rung 1: entity_signals (provenance-ordered)
    if let l = lexicalMatch(s), l.margin >= minMargin { return l }  // rung 2: high-margin only
    return .unclassified(s)                        // Phase 6: → rungs 3–5 via the TidyAI router
}
```

The exact scoring, margin threshold, and token normalization are spelled out in
[understand-layer.md](../architecture/understand-layer.md) /
[classification-ladder.md](../architecture/classification-ladder.md); keep them local and
deterministic.

---

## 4. Sessionization (completing the timeline)

The **full `Sessionizer`** for screen sessions lands here
([understand-layer.md §1](../architecture/understand-layer.md#1-sessionization)) — Phase 4 shipped
only the Slack slice. It collapses `activity_samples` into `kind='screen'` sessions on a normalized
`context_key`, using two `config.sessionization` knobs:

| Config key | Default | Meaning |
|---|---|---|
| `sessionization.detour_tolerance_seconds` | `120` | a sub-tolerance run bracketed by the same context is **absorbed** (a 90 s Slack glance inside an hour of EN work doesn't split it) |
| `sessionization.min_session_seconds` | `60` | finalized sub-minimum sessions are dropped/folded |

All three `kind`s — `screen` (this pass), `meeting` (Phase 3 ingest), `slack` (Phase 4) — live in
the one `sessions` table and merge into one timeline by `started_at`. Classification (§2–§3) runs
as a separate pass that fills the attribution columns.

---

## 5. Suggestion engine (`TidySuggest`)

Classified sessions for a day become `suggestions`. Detail in
[suggestion-engine.md](../architecture/suggestion-engine.md); Phase 5 builds the **local** subset
(everything except transcript-driven meeting splitting, which is rung-4 = Phase 6).

### 5.1 Rounding + round-up bias

Group a day's classified sessions by `task_id` (or by `project_id` when only project resolved), sum
real seconds, and round to `config.suggestions.increment_minutes` (15) with
`config.suggestions.round_up_bias` (0.4):

```swift
// TidySuggest/Rounding.swift
/// increment=15 min, bias=0.4. Bias lowers the round-up threshold from 0.5 toward 0.
/// bias 0 → nearest; bias 1 → always up. bias 0.4 → round up once ≥30% into an increment.
func roundedMinutes(rawSeconds: Int, incrementMin: Int, bias: Double)
    -> (minutes: Int, roundedUp: Bool) {
    let inc = Double(incrementMin * 60)
    let increments = Double(rawSeconds) / inc
    let base = floor(increments)
    let frac = increments - base
    let upThreshold = 0.5 * (1.0 - bias)                 // 0.4 → 0.30
    let steps = (frac > 0 && frac >= upThreshold) ? base + 1 : base
    let minutes = Int(steps) * incrementMin
    return (minutes, frac > 0 && steps == base + 1)      // roundedUp flag → suggestions.is_rounded_up
}
```

Examples (increment 15, bias 0.4 → threshold 0.30): 22 min → `30` (up); 16 min → `15` (down);
44 min → `45` (up). Store `minutes` (rounded), `raw_seconds` (pre-rounding, for the "rounded from …"
label), and `is_rounded_up`.

Anything **at or above** `config.suggestions.standalone_threshold_minutes` (15) of *real* time
becomes a standalone `kind='session'` suggestion; anything below goes to a **pool** (§5.2).

### 5.2 Micro-work pools

Sub-threshold fragments accumulate per project across the day so the little things don't evaporate
(PLAN §8). Pools live in the `pools` table:

- **Key:** `(day, project_id)` (carry `client_id` too). Each contributing session appends to
  `items_json` (`[{session_id, seconds, blurb}]`), bumping `accumulated_seconds` and `item_count`.
- **Roll-up trigger:** when `accumulated_seconds` crosses one increment (15 min) **or** at recap
  time, the pool becomes **one** `kind='pool'` suggestion with an itemized note
  ("Slack: helped Nick debug ENgrid selector; reviewed staging link; replied to Sebrinia re:
  timeline."). Set `pools.status = 'rolled_up'` → `'suggested'`, link `pools.suggestion_id`.
- Slack drive-by sessions from Phase 4 are the primary pool feed (phase-4-slack.md §6). A pool that
  never crosses the increment by recap time still surfaces (rounded up per bias) so nothing is lost.

### 5.3 Meetings (whole-block in Phase 5)

Per-client **transcript splitting** ("14 min Client A, 6 min Client B, remainder internal") is a
rung-4 job and lands in **Phase 6** ([suggestion-engine.md](../architecture/suggestion-engine.md);
PLAN §8). In Phase 5 each meeting becomes a **single** suggestion:

- Duration = the Fathom **recording** span (`meetings.recording_start`/`recording_end`) — ground
  truth, not the calendar slot (rounded per §5.1).
- Attribution via rungs 1–2: `meeting_invitees.email_domain` (`email_domain`/`person_email`
  signals) and `meetings.title` (`meeting_title` signal). External invitees are a strong client
  signal.
- `kind='meeting_segment'` with a single full-duration segment (the schema `kind` value is reused;
  Phase 6 emits several `meeting_segment` rows per meeting once transcript splitting exists).
- Unrecorded meetings fall back to the `calendar_events` slot + attendee/title signals.

### 5.4 Gap analysis (only suggest what's missing)

Before finalizing the stack, reconcile against what's already logged so the recap never
double-suggests (PLAN §8):

- Load `pd_time_entries` for `person_id = self` and `date = day` (Phase 2 mirror).
- Sum reconstructed attributed minutes per task/project; subtract already-logged `time_minutes`.
  Emit suggestions only for the **remainder**.
- **Flag disagreements** rather than hiding them: when observed and logged diverge by ≥ one
  increment (`increment_minutes`), surface a note ("you logged 1h on Task X; I saw ~2h15m") instead
  of a silent suggestion.

```sql
-- Already-logged minutes for the day, per task (gap-analysis input).
SELECT task_id, project_id, SUM(time_minutes) AS logged_minutes
FROM   pd_time_entries
WHERE  person_id = :self_person_id AND date = :day
GROUP  BY task_id, project_id;
```

### 5.5 New-task proposals

When work clearly belongs to a client/project (a rung-1 rule fired on the project) but **no** open
`pd_tasks` row matches lexically, propose a task instead of forcing a wrong one (PLAN §8):

- `kind='new_task'`, `client_id`/`project_id` set, `task_id` NULL, `proposed_task_title` +
  `proposed_task_description` filled (copy-ready). The user creates it in Productive; the next
  Phase-2 sync picks it up and a later recap re-links to the real `task_id`.
- v1 form: rule-known project + lexical no-match. (PLAN's "rung 3/4 agrees" strengthening is Phase
  6; a Phase-5 new-task proposal is confidence-tagged accordingly.)

### 5.6 Notes & billable inference (local, template-based)

- **Notes** are generated **locally** from the session's title/context/pool items — no AI draft
  (that's Phase 6). One–two sentences, editable in the card.
- **Billable:** infer `suggestions.billable` from the project: `pd_projects.project_type_id = 2`
  (client/deliverable) → `1`; `= 1` (internal) → `0`; unknown → NULL. Drives the recap's
  billable/internal split and `daily_rollups`.
- **Deep link:** fill `suggestions.deep_link` from `config.productive.task_deep_link_pattern`
  (⚠️ Build-time check — pattern captured from the web app in Phase 2).

### 5.7 Daily rollups

Populate `daily_rollups` for the day (used by the recap header now; the full dashboard UI is Phase
6): `observed_seconds`, `attributed_seconds`, `logged_minutes`, `billable_minutes`,
`internal_minutes`, `per_client_json`, `capture_health = attributed/observed`. `ai_cost_usd` stays
`0` (no AI this phase).

---

## 6. The recap window (`TidySurface`)

A real window (not the cramped popover) — layout per PLAN §9 and
[surface-layer.md](../architecture/surface-layer.md):

- **Left — the day as a vertical timeline.** Screen sessions colored by client, meetings, Slack
  sessions, away gaps, and already-logged `pd_time_entries` overlaid, ordered by `started_at`.
- **Right — the suggestion stack**, sorted by `confidence` descending; **pools** and open
  **`resolution_questions`** pinned at the bottom.

### 6.1 Suggestion card anatomy (PLAN §8)

```
 Client › Project › Task            (or "Propose new task: <title>")
 1h 15m · confidence ●●●○ · why: matched EN account 'exampleorg'
 Note: one–two sentences, editable
 [Copy note] [Copy all] [Open task in Productive] [Log it ✓] [Edit] [Reassign] [Toss]
```

- **`Copy note`** → note text to clipboard. **`Copy all`** → duration + note together (paste-ready).
- **`Open task in Productive`** → `suggestions.deep_link`.
- **`Log it ✓`** marks the suggestion **handled locally only** (`suggestions.status = 'logged'`) and
  feeds gap analysis/metrics — **it never calls Productive** (G1). The human makes the actual entry.
- **`Edit` / `Reassign` / `Toss`** update the suggestion and write a `decisions` row (§9).

### 6.2 Timing, morning catch-up, queueing

- Fires at `config.recap.time` (default `17:00`) in `config.organization.timezone`
  (`America/New_York`).
- **Morning catch-up:** if a day closes **unreconciled**, the same recap opens for *yesterday* at
  the user's first activity next morning (`config.recap.morning_catchup = true`). Skipped days
  **queue** and are worked oldest-first.
- Days are `YYYY-MM-DD` in the configured local zone (data-model.md conventions) — the unit both the
  recap and Productive think in.

---

## 7. Ask-once resolution questions

When a **recurring** signal can't be resolved (a domain seen daily, an unmatched channel, an EN
account with no client), don't guess repeatedly — enqueue one question
([understand-layer.md §2.4](../architecture/understand-layer.md#24-ask-once-unresolved-signals--resolution_questions)):

- Insert a `resolution_questions` row (`question`, `signal_type`, `signal_value`, `status='open'`).
  `UNIQUE(signal_type, signal_value)` guarantees the same unknown is asked **once**. Gate on a
  minimum `hit_count` across distinct days so a stray one-off never asks.
- The recap renders open questions at the bottom of the stack.
- **On answer:** set `status='answered'`, `answer_client_id`/`answer_project_id`, `answered_at`,
  **and** upsert an `entity_signals` row with `provenance='user_confirmed'`. Answer once, it's a
  rule forever — the next same-context session classifies at rung 1.
- **On dismiss:** `status='dismissed'`; not re-asked for that signal.

---

## 8. Decisions & the learning loop

Every recap action writes a `decisions` row — the training signal — and feeds the deterministic,
no-ML learning loop ([understand-layer.md §4](../architecture/understand-layer.md#4-learning-loop-rules--examples-no-training-no-embeddings-in-v1)):

| Action (`decisions.action`) | Effect |
|---|---|
| `reassign` | upsert/strengthen the responsible `entity_signals` row as `user_confirmed` (bump `weight`/`hit_count`). Reassign the same signal twice → it's a rule that outranks all. |
| `accept` / `log` | reinforce the winning signal (`weight`/`hit_count`/`last_seen_at`). |
| `edit` (duration) | feeds rounding/round-up-bias tuning; no signal change. |
| `toss` | weaken the responsible signal (decrement `weight`); repeated tosses retire an `inferred` signal. |
| `snooze` | defers the suggestion to a later recap (`suggestions.status='snoozed'`). |

Store `before_json`/`after_json` snapshots so an edit/reassign is auditable. **Few-shot examples**
for rungs 3–4 are a Phase-6 use of `decisions`; Phase 5 only needs the rules-strengthening paths.
The promotion path is why most work eventually lands free on rung 1 (G4).

---

## 9. Schema & migration

All six tables are defined verbatim in
[data-model.md → Understand & suggest](../architecture/data-model.md#understand--suggest-phase-5).
Add them in **one new GRDB migration** (never edit a shipped one). Order matters for the foreign
keys — create referenced tables first:

```swift
// TidyStore/Migrations.swift
migrator.registerMigration("v1-understand-suggest") { db in
    // 1. entity_signals            (FKs → pd_companies/pd_projects, exist since Phase 2)
    // 2. resolution_questions      (FKs → pd_companies/pd_projects)
    // 3. suggestions               (FKs → pd_companies/pd_projects/pd_tasks) — before pools/decisions
    // 4. pools                     (pools.suggestion_id → suggestions.id)
    // 5. decisions                 (decisions.suggestion_id → suggestions.id)
    // 6. daily_rollups
    // Exact CREATE TABLE + index DDL is in data-model.md — copy it verbatim.
}
```

- `sessions` already exists (Phase 1); Phase 5 only *writes* its attribution columns
  (`client_id`/`project_id`/`task_id`/`confidence`/`produced_by_rung`/`rationale`/`classified_at`).
  No schema change to `sessions`.
- In `DEBUG`, `eraseDatabaseOnSchemaChange = true` speeds iteration; **never** in release.
- Retention (G9): `entity_signals`, `suggestions`, `decisions`, `pools`, `daily_rollups` are
  **distilled artifacts** — they **persist** past the 90-day window (data-model.md Retention).

---

## 10. Config additions

Phase 5 uses config keys that already exist in `config.example.json` — **do not invent new ones**:

```json
{
  "organization": { "timezone": "America/New_York", "productive_person_id": "resolved_at_setup" },
  "productive":   { "task_deep_link_pattern": "https://app.productive.io/{org}/task/{task_id}" },
  "sessionization": { "detour_tolerance_seconds": 120, "min_session_seconds": 60 },
  "suggestions":  { "increment_minutes": 15, "round_up_bias": 0.4, "standalone_threshold_minutes": 15 },
  "recap":        { "time": "17:00", "morning_catchup": true }
}
```

- `suggestions.*` drive rounding (§5.1) and the pool/standalone threshold (§5.2).
- `recap.time` + `organization.timezone` drive recap firing; `recap.morning_catchup` drives the
  next-morning queue (§6.2).
- `productive.task_deep_link_pattern` fills `suggestions.deep_link` (⚠️ Build-time check — Phase 2).
- The gap-analysis disagreement tolerance reuses `suggestions.increment_minutes` (§5.4) — no new
  key. If a separate tolerance proves needed, add it in a later change (don't invent it here).

---

## 11. File & function manifest

Under `Packages/TidyKit/Sources/` (run `make generate` after adding files).

| File | Contents |
|---|---|
| `TidyUnderstand/EntityRegistry.swift` | bootstrap from `pd_*`; upsert signals; provenance-ordered lookup (§2) |
| `TidyUnderstand/Sessionizer.swift` | full screen-session collapse (§4); Slack/meeting session assembly reuse |
| `TidyUnderstand/Classifier.swift` | rung 1 (rules) + rung 2 (lexical, high-margin); `.unclassified` fall-through (§2–§3) |
| `TidyUnderstand/Lexical.swift` | tokenization, TF-weighted scoring against the `pd_*` corpus |
| `TidyUnderstand/ResolutionQuestions.swift` | recurring-unknown detection → `resolution_questions`; answer → `user_confirmed` signal (§7) |
| `TidyUnderstand/LearningLoop.swift` | apply `decisions` → strengthen/weaken signals, tune bias (§8) |
| `TidySuggest/Rounding.swift` | `roundedMinutes(...)` (§5.1) |
| `TidySuggest/Pools.swift` | per-project accumulation, roll-up trigger, itemized notes (§5.2) |
| `TidySuggest/MeetingSuggest.swift` | whole-block meeting suggestion at Fathom duration (§5.3) |
| `TidySuggest/GapAnalysis.swift` | reconcile vs `pd_time_entries`; disagreement flags (§5.4) |
| `TidySuggest/NewTaskProposal.swift` | rule-known project + lexical no-match → proposed task (§5.5) |
| `TidySuggest/NoteTemplater.swift` | local template notes; billable inference; deep-link fill (§5.6) |
| `TidySuggest/DailyRollup.swift` | populate `daily_rollups` (§5.7) |
| `TidySurface/Recap/RecapWindow.swift` | window scene; timeline + card-stack layout (§6) |
| `TidySurface/Recap/TimelineView.swift` | vertical timeline, client colors, logged-entry overlay |
| `TidySurface/Recap/SuggestionCard.swift` | card anatomy + Copy/Open/Log/Edit/Reassign/Toss (§6.1) |
| `TidySurface/Recap/RecapScheduler.swift` | recap-time firing, morning catch-up, day queue (§6.2) |
| `App/…` | wire the recap window into the `MenuBarExtra` "open recap" action |

Dependencies (module-map.md): `TidyUnderstand` → `TidyStore`/`TidyCore`; `TidySuggest` →
`TidyStore`/`TidyUnderstand`/`TidyCore` (may reference the `TidyAI` router but must degrade when
absent — in Phase 5 it simply isn't invoked); `TidySurface` → `TidyStore`/`TidySuggest` read models
only (no capture, no network, no provider calls).

---

## 12. Testing

Fixtures + in-memory GRDB, no live network (`make test`). Assert:

- [ ] **Sessionization:** a day of `activity_samples` reads back as merged same-context sessions;
      sub-`min_session_seconds` fragments gone; sub-`detour_tolerance_seconds` glances absorbed
      (understand-layer.md acceptance).
- [ ] **Rung 1:** a session whose `context_key` matches a `bootstrapped` signal classifies at
      `produced_by_rung = 1` with the right client/project and a rationale; a `user_confirmed`
      signal beats a conflicting `bootstrapped` one.
- [ ] **Rung 2:** a high-margin lexical match classifies; a near-tie stays **unclassified** (no
      model called — `ai_calls` empty; G4).
- [ ] **Rounding:** table-driven cases (22→30 up, 16→15 down, 44→45 up); `is_rounded_up` set
      correctly.
- [ ] **Pools:** N sub-threshold slack sessions on one project accumulate and roll up into one
      `kind='pool'` suggestion with an itemized note once past 15 min (or at recap).
- [ ] **Gap analysis:** given a `pd_time_entries` row for the day, only the *remaining* minutes are
      suggested; an over/under logged task raises a disagreement flag, not a duplicate suggestion.
- [ ] **New-task proposal:** rule-known project + no lexical task match → `kind='new_task'` with
      title/description and `task_id` NULL.
- [ ] **Resolution question:** a recurring unknown creates exactly one `resolution_questions` row;
      answering upserts a `user_confirmed` `entity_signals` row and the next same-context session
      classifies at rung 1.
- [ ] **Decisions / G1:** `Log it ✓` sets `status='logged'` and writes a `decisions` row and makes
      **no** Productive request (guardrail test: no non-GET to `api.productive.io`, and no request
      at all from the recap action).
- [ ] **Reassign learning:** reassigning the same signal twice makes it a `user_confirmed` rule that
      outranks the prior guess.

---

## 13. Guardrails that bind this phase

| Guardrail | How Phase 5 satisfies it |
|---|---|
| **G1** (read-only Productive) | The recap **never writes** to Productive. `Log it ✓` is local-only (`suggestions.status`); the only Productive traffic is the Phase-2 read sync. A guardrail test asserts no request originates from any recap action (§6.1, §12). |
| **G4** (local-first ladder) | Only rungs 1–2 run; a session they can't settle is left unclassified rather than escalated. No cloud/on-device call exists in this phase — `ai_calls` stays empty (§1, §3). |
| **G2** (sensitivity gate) | Deferred to Phase 6 (ships with the first cloud call). Phase 5 notes are local templates; nothing leaves the device, so the gate is not yet load-bearing. `is_sensitive` seams remain in place (§1). |
| **G9** (retention) | The six new tables are **distilled artifacts** and persist past the 90-day window; they are *derived from* raw rows that purge (data-model.md Retention). |

---

## 14. Gotchas & phase boundaries

- **Unclassified is a valid outcome.** Rungs 1–2 will not settle everything; those sessions show on
  the timeline without a confident card. That's expected pre-AI — do not force a low-confidence
  guess. Phase 6 closes the gap.
- **Cold start needs corrections.** Weeks 1–2 of suggestions ask more resolution questions and
  deserve more reassignments — that's the learning loop's diet, not a failure (PLAN §12). The recap
  is designed so a wrong guess costs one tap.
- **Meetings are whole-block here.** Per-client transcript splitting (the "15 min inside an
  hour-long call" magic) needs rung 4 and lands in **Phase 6**; Phase 5 attributes the whole
  recording to the dominant client/internal via rungs 1–2 (§5.3).
- **`Log it ✓` ≠ writing to Productive.** It is a local status change (G1). Copy-paste is the actual
  entry path in v1 — the acceptance's "reaches Productive" is the human pasting a recap-surfaced
  block.
- **Provenance value is `inferred`, not "learned".** Match data-model.md; "learned" is prose only.
- **Day boundaries are local-zone `YYYY-MM-DD`.** Sessions store UTC epoch seconds; convert through
  `config.organization.timezone` when bucketing into a recap day, or a late-evening session lands on
  the wrong day.
- **Deep-link pattern is a build-time check.** Don't hard-code it; read
  `config.productive.task_deep_link_pattern` (⚠️ captured from the web app in Phase 2).

---

## 15. Definition of done

- [ ] `make build` + `make test` green; the `v1-understand-suggest` migration adds the six tables
      per data-model.md; `data-model.md` unchanged (already canonical) or updated if reality
      diverged.
- [ ] A real workday opens in the recap with a coherent timeline + confidence-sorted card stack;
      reconciling it takes **under ten minutes**.
- [ ] At least one **forgotten billable block** surfaced by the recap is copy-pasted into
      Productive (the headline acceptance).
- [ ] Gap analysis suppresses double-suggestions and flags disagreements; an ask-once question,
      once answered, produces a rung-1 `user_confirmed` rule.
- [ ] Guardrail tests green: no Productive write from the recap (G1); no model call (G4);
      distilled tables persist (G9).
- [ ] Phase docs / acceptance criteria reflect any behavior that changed during the build.

**Next:** [Phase 6 — Intelligence](phase-6-intelligence.md) adds the sensitivity gate, the
on-device rung, the metered cloud router + `ai_calls` ledger, economy-tier + Claude escalation,
transcript-driven meeting splitting, nudges, and the dashboard — on top of this working recap.
