# Understand layer (TidyUnderstand)

Turns raw capture + ingest into classified `sessions`: sessionization, the entity-signal
client registry, the fail-closed sensitivity gate, and the rules-and-examples learning loop.
Implements PLAN §7's local rungs; the cloud rungs live one door down in the ladder.

**Related:** [doc index](../README.md) · [PLAN §7](../../PLAN.md) ·
[classification ladder](classification-ladder.md) · [data model](data-model.md) ·
[module map](module-map.md) · [guardrails](../guardrails.md)

---

## Where this sits

`TidyUnderstand` consumes what `TidyCapture` and `TidyIngest` wrote to `TidyStore`, and
produces classified `sessions` plus a maintained `entity_signals` registry. It owns the
ladder's **local** rungs (1 rules, 2 lexical), the **sensitivity gate**, and the **learning
loop**; it may call the `TidyAI` router for rungs 3–5 but must degrade gracefully when the
router is unavailable (budget cap tripped, Apple Intelligence off) — see
[module-map.md](module-map.md) and [guardrails.md](../guardrails.md) G4.

```
capture (activity_samples, page_snapshots, away_gaps)
ingest  (meetings, transcript_utterances, slack_messages, calendar_events, pd_*)
        │
        ▼
  ┌───────────────── TidyUnderstand ─────────────────┐
  │ 1. Sessionizer      → sessions (screen/meeting/slack) │
  │ 2. ClientRegistry   → entity_signals + resolution_questions │
  │ 3. SensitivityGate  → is_sensitive, GatedPayload (G2) │
  │ 4. Classifier ladder rungs 1–2 (→ TidyAI for 3–5)     │
  │ 5. LearningLoop     → strengthen signals, tune thresholds │
  └───────────────────────────────────────────────────────┘
        │
        ▼
   TidySuggest (rounding, pools, meeting split, gap analysis)
```

Everything below writes through `TidyStore` DAOs; `TidyUnderstand` performs no network or
Accessibility I/O of its own.

---

## 1. Sessionization

A **session** is a contiguous block of focused time on one *context* — a client's EN admin, a
Google Doc, a Slack thread, a Zoom call. Sessions (`sessions` table) are the unit everything
downstream classifies, pools, and rounds. There are three `kind`s, and only one is built from
screen samples:

| `sessions.kind` | Built from | `source_ref` |
|---|---|---|
| `screen` | collapsing `activity_samples` (this section) | `NULL` |
| `meeting` | `meetings` + `transcript_utterances` (ingest) | Fathom `meetings.id` |
| `slack`   | `slack_messages` grouped by conversation (ingest) | `conversation_id` |

### 1.1 Screen sessions: collapse `activity_samples`

Raw samples (one per app/window switch plus a 30 s heartbeat) collapse into sessions by a
normalized key. **Two levels, deliberately:** sessions GROUP on the fine
`ContextKey.grouping` key (coarse key + normalized window/tab title +, when
`capture.separate_chats_by_path` is on, the URL **path identity** — query/fragment dropped), while
the coarse **`context_key`** (`web:<host>` / `app:<bundle>`) is what gets STORED on the session and
is what rung-1 domain rules match. That split is why two chats in one window can attribute to
different projects while host rules still converge. All normalization lives in
`TidyCore.ContextSignature`, shared with capture gating and the context-switch metric.
Two knobs from `config.json` govern the collapse:

| Config key | Default | Meaning |
|---|---|---|
| `sessionization.detour_tolerance_seconds` | `120` | A different-context run shorter than this, bracketed by the same context on both sides, is **absorbed** — a 90 s glance at Slack inside an hour of EN work does not split the EN session. |
| `sessionization.min_session_seconds` | `60` | Finalized sessions shorter than this are dropped (folded into a same-context neighbor, else discarded as noise). |

**`context_key` derivation** (normalized, lowercased) — the dominant signal of a sample:

| Sample shape | `context_key` |
|---|---|
| browser sample (`is_browser = 1`) | registrable host of `url` (e.g. `staging.example.org`), or the EN-account / staging token if present in `page_snapshots.text` |
| native app with a document-ish window title | `app_bundle_id` + `‖` + normalized window title stem |
| native app, generic | `app_bundle_id` |

Keep `context_key` coarse enough that ordinary back-and-forth stays one session, but fine
enough that two clients' tabs don't merge. Store the winning key on `sessions.context_key`;
it is the primary input to rung 1.

### 1.2 Sessionization sketch

```swift
/// Collapses ordered `activity_samples` (one day's worth) into draft screen `sessions`.
/// Meeting/Slack sessions are built separately (see §1.3) and share the same table.
struct Sessionizer {
    let detourTolerance: TimeInterval    // sessionization.detour_tolerance_seconds (120)
    let minSessionLength: TimeInterval   // sessionization.min_session_seconds     (60)

    func screenSessions(from samples: [ActivitySample], now: Int) -> [DraftSession] {
        // 1. Tag each sample with its normalized context key.
        let tagged: [(sample: ActivitySample, key: String)] =
            samples.map { ($0, ContextKey.derive(from: $0)) }

        var drafts: [DraftSession] = []
        for (i, item) in tagged.enumerated() {
            let start = item.sample.startedAt
            let end   = item.sample.endedAt ?? now          // NULL ended_at = still current
            guard end > start else { continue }

            if var open = drafts.last, open.contextKey == item.key {
                open.endedAt = end                          // same context → extend
                drafts[drafts.count - 1] = open
            } else if var open = drafts.last,
                      Double(end - start) < detourTolerance,
                      nextKey(after: i, in: tagged) == open.contextKey {
                open.endedAt = end                          // brief detour, returns → absorb
                drafts[drafts.count - 1] = open
            } else {
                drafts.append(DraftSession(kind: .screen,
                                           contextKey: item.key,
                                           startedAt: start,
                                           endedAt: end,
                                           primaryApp: item.sample.appName))
            }
        }

        // 2. Finalize (sets duration_seconds + title), drop sub-minimum fragments.
        return drafts
            .map { $0.finalized() }
            .filter { $0.durationSeconds >= Int(minSessionLength) }
    }

    /// Look-ahead: the key immediately following index `i`, ignoring nothing.
    /// Production may prefer a two-pass merge; this streaming form is enough to reason about.
    private func nextKey(after i: Int, in tagged: [(sample: ActivitySample, key: String)])
        -> String? { i + 1 < tagged.count ? tagged[i + 1].key : nil }
}
```

`DraftSession.finalized()` computes `duration_seconds = ended_at − started_at`, derives a
human `title` (e.g. the tab/doc name), and leaves the attribution columns
(`client_id`/`project_id`/`task_id`/`confidence`/`produced_by_rung`/`rationale`) **NULL** —
classification is a separate pass (rungs 1–2 here, 3–5 via the router).

### 1.3 Meeting & Slack sessions (from ingest, not screen samples)

- **Meeting sessions** (`kind = 'meeting'`). One session per `meetings` row.
  `duration_seconds` comes from the Fathom **recording** span (`recording_start`/
  `recording_end`), not the calendar slot — the calendar only supplies schedule and
  attendees. `source_ref` = the Fathom `meetings.id`. The per-client *split* of a meeting is
  downstream (ladder rung 4 + [suggestion-engine.md](suggestion-engine.md)); here we only
  materialize the session row. Overlapping screen activity during a meeting window is labeled
  in-meeting context, not a separate work session.
- **Slack sessions** (`kind = 'slack'`). Group `slack_messages` by `conversation_id`; a burst
  of activity on one conversation (author = self, plus surrounding context) becomes one
  session with `source_ref = conversation_id`. Most are sub-threshold and feed pools rather
  than standalone suggestions ([suggestion-engine.md](suggestion-engine.md)).

All three kinds land in the same `sessions` table and merge into one timeline by
`started_at`.

---

## 2. Entity resolution — the client registry (`entity_signals`)

The registry maps observables to `client_id`/`project_id`. It is both rung 1's knowledge base
and the thing the learning loop grows.

### 2.1 `signal_type` taxonomy (exact — from [data-model.md](data-model.md))

`entity_signals.signal_type` is exactly one of:

| `signal_type` | `signal_value` (normalized) | Typical source |
|---|---|---|
| `email_domain` | registrable domain, lowercased | `meeting_invitees.email_domain`, calendar attendees |
| `slack_channel` | channel id | `slack_messages.conversation_id` |
| `staging_url` | host (+ path stem) of a staging/preview URL | `activity_samples.url`, page text |
| `url_host` | registrable host | `activity_samples.url` |
| `en_account` | EN account name/slug, lowercased | `page_snapshots.text`, window title |
| `person_email` | full email, lowercased | attendees, Slack users |
| `keyword` | lowercased token/phrase | `pd_projects.name`, `pd_tasks.title` tokens |
| `meeting_title` | normalized title stem | `meetings.title`, `calendar_events.title` |

`UNIQUE(signal_type, signal_value)` — one row per observable; re-observation bumps
`hit_count`/`last_seen_at`, it does not insert a duplicate.

### 2.2 Bootstrap from Productive vocabulary (setup / Phase 5)

At setup, seed `entity_signals` from the Productive cache — no capture required yet:

| Productive source | → `signal_type` | `provenance` |
|---|---|---|
| `pd_companies.domain` | `email_domain`, `url_host` | `bootstrapped` |
| `pd_companies.name` tokens | `keyword` | `bootstrapped` |
| `pd_projects.name` tokens | `keyword` (→ `project_id`) | `bootstrapped` |
| `pd_tasks.title` distinctive tokens | `keyword` | `bootstrapped` |

Bootstrapped signals come straight from Productive's authoritative vocabulary. As capture
runs, cross-referencing what the watcher/ingest sees against these (and against each other —
a channel whose members map to a known client, a domain seen on meeting invitees) mints new
signals with `provenance = 'inferred'`.

> ⚠️ Doc drift: [PLAN.md](../../PLAN.md) §7 and [glossary.md](../glossary.md) call the middle
> provenance "learned"; the canonical column value in [data-model.md](data-model.md) is
> **`inferred`**. Use `inferred` in code and prose; "learned" is a synonym only.

### 2.3 Provenance precedence (conflict resolution)

When more than one signal matches a session and they disagree, resolve by **provenance first,
then `weight`, then `hit_count`**:

```
user_confirmed  >  bootstrapped  >  inferred
   (human said)     (from Productive)   (our guess)
```

- **`user_confirmed` outranks everything** — a rule born from the user's own answer or a
  reassignment (PLAN §7: "Rules born from your answers outrank inferred ones"). This is the
  correction channel: a wrong `bootstrapped`/`inferred` signal is overridden by promoting a
  `user_confirmed` one, never by silently mutating the original.
- **`bootstrapped` outranks `inferred`** — Productive's own vocabulary beats a heuristic guess.
- Within the same provenance, higher `weight` wins; ties break on `hit_count`, then most
  recent `last_seen_at`.

### 2.4 Ask-once: unresolved signals → `resolution_questions`

When a **recurring** signal can't be resolved (a domain seen daily, an unmatched channel, an
EN account with no client), do not guess repeatedly — enqueue one question and surface it in
the recap:

- Insert a `resolution_questions` row: `question` ("Which client is `staging.example.org`?"),
  `signal_type`, `signal_value`, `status = 'open'`. `UNIQUE(signal_type, signal_value)` means
  the same unknown is only ever asked once.
- The recap renders open questions at the bottom of the stack
  ([surface-layer.md](surface-layer.md)).
- On answer: set `status = 'answered'`, `answer_client_id`/`answer_project_id`, `answered_at`,
  **and** upsert a matching `entity_signals` row with `provenance = 'user_confirmed'`. Answer
  once, it's a rule forever.
- Dismissing a question sets `status = 'dismissed'`; it is not re-asked for that signal.

"Recurring" (not one-off) is the trigger — gate on a minimum `hit_count` across distinct days
so a single stray domain never generates a question.

---

## 3. Sensitivity gate (fail-closed — guardrail [G2](../guardrails.md))

A local keyword/participant screen that keeps personnel, performance, compensation, legal, and
user-flagged content out of any cloud payload and out of generated notes.

**When it runs.** Before a session is allowed to climb to **rung 3 (on-device) or rung 4
(cloud)**, and before **any note is generated** (PLAN §7). Rung 3 is on-device and technically
exempt from *transmission* concerns (G2), but the gate still short-circuits it so the
generic-task-and-bland-note fallback is applied *consistently* regardless of which rung would
have run.

**Inputs it screens.** The distilled session digest the ladder would send: window/tab titles,
`page_snapshots.text`, transcript utterances, Slack text — plus the meeting/session
participants against `config.sensitivity.flagged_people`.

**Decision.**

```
gate(digest, participants) -> .clear | .sensitive
  sensitive  ⇐  any config.sensitivity.keywords / flagged_terms present
            OR  any participant in config.sensitivity.flagged_people
            OR  the classifier cannot decide            // uncertainty ⇒ sensitive
```

**On `.sensitive`:**
1. Set `sessions.is_sensitive = 1` (propagates to `suggestions.is_sensitive`).
2. **Do not** call rungs 3–5; resolve locally (rungs 1–2) or leave unclassified.
3. Suggestion defaults to the appropriate **generic task** (e.g. "1:1 check-in") with a
   **bland note**; no cloud note draft.
4. Nothing sensitive appears in any outbound payload — verifiable via the local
   outbound-payload log (Phase 6 acceptance, G2).

**On `.clear`:** produce a `GatedPayload` — the *only* value type the `TidyAI` cloud clients
accept (see [module-map.md](module-map.md) `SensitivityGate` seam;
[classification-ladder.md](classification-ladder.md) for how the router consumes it). The gate
never disables itself: an empty user list still runs the shipped default keywords.

Rationale for fail-closed (PLAN §7): an over-cautious generic note costs one manual edit; the
opposite failure writes "discussed PIP for \[name]" into a time log.

---

## 4. Learning loop (rules + examples; no training, no embeddings in v1)

Every recap action is a training signal. The loop is deterministic bookkeeping over
`decisions`, `entity_signals`, and thresholds — PLAN §7 is explicit that v1 has **no model
training and no embeddings**; rules plus few-shot examples capture most of the value.

| Signal (source) | Effect |
|---|---|
| **Reassign** (`decisions.action = 'reassign'`) | Upsert/strengthen the responsible `entity_signals` row with `provenance = 'user_confirmed'` (bump `weight`/`hit_count`). Reassign `staging.example.org` twice → it's a rule (`user_confirmed` outranks all). |
| **Accept** (`accept`/`log`) | Reinforce the winning signal: bump `weight`/`hit_count`/`last_seen_at` on the signal that produced the classification. |
| **Edit duration** (`edit`) | Feeds the rounding/round-up bias tuning in [suggestion-engine.md](suggestion-engine.md); no signal change. |
| **Toss** (`toss`) | Weakens the responsible signal (decrement `weight`); repeated tosses can retire an `inferred` signal. |
| **Dismissed nudge** (`nudges.outcome = 'dismissed'`) | Raise that `context_key`'s effective nudge threshold — the same context must classify *more* confidently before nudging again ([surface-layer.md](surface-layer.md)). |
| **Recent decisions** | The last N `decisions` for a context ride along as **few-shot examples** in the rung 3/4 prompts, biasing the models toward the user's demonstrated choices. |

Promotion path (why most work eventually lands free on rung 1): confirmed patterns become
high-`weight` `user_confirmed`/`bootstrapped` signals, so `context_key`s that once needed a
model now match a deterministic rule. A rising "share resolved on-device/free" is the
dashboard signal that the loop is working (G4).

---

## Acceptance criteria (Phase 5, extended Phase 6)

- A full workday of `activity_samples` reads back as a coherent `sessions` timeline: same-
  context runs merged, sub-`min_session_seconds` fragments gone, sub-`detour_tolerance_seconds`
  glances absorbed rather than splitting the surrounding session.
- Meeting sessions show Fathom-true `duration_seconds`; Slack sessions group by conversation.
- Bootstrap seeds `entity_signals` from the Productive cache; a recurring unknown produces
  exactly one `resolution_questions` row, and answering it upserts a `user_confirmed` signal
  that outranks the prior guess.
- A seeded sensitive phrase sets `is_sensitive = 1`, forces the generic-task/bland-note
  fallback, and appears in **no** outbound payload (shared with
  [classification-ladder.md](classification-ladder.md) / G2).
- Reassigning the same signal twice makes the next same-context session classify at rung 1
  with a `user_confirmed` rationale.
