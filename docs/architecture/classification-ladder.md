# Classification ladder

The five-rung local-first → cheap → smart escalation path that attributes a `session` to a
client/project/task, the **exact** fall-through condition between each rung, how the producing
rung is recorded, and the budget cap that drops the app to local-only. Implements PLAN §7 and
enforces guardrails [G4](../guardrails.md) and [G5](../guardrails.md).

**Related:** [doc index](../README.md) · [PLAN §7](../../PLAN.md) ·
[understand layer](understand-layer.md) · [data model](data-model.md) ·
[guardrails](../guardrails.md) · [AI provider router](../conventions/ai-provider-router.md)

---

## Principle (G4)

Each session climbs **only as far as it must**. A session a rule or a high-margin lexical
match can settle **must not** reach a cloud model. Rungs 1–2 are local and free
(`TidyUnderstand`); rungs 3–5 go through the `TidyAI` router
([ai-provider-router.md](../conventions/ai-provider-router.md)) and are metered into `ai_calls`
(G5). The **sensitivity gate runs before rungs 3 & 4** — sensitive sessions never enter the
model path (see [understand-layer.md](understand-layer.md) §3).

| Rung | Name | Where | Cost | Records `produced_by_rung` |
|---|---|---|---|---|
| 1 | Deterministic rules | `TidyUnderstand` | free/local | `1` |
| 2 | Lexical matching | `TidyUnderstand` | free/local | `2` |
| 3 | On-device model (Apple Foundation Models) | `TidyAI` router | free/local | `3` |
| 4 | Economy cloud (Fireworks AI) | `TidyAI` router | metered $ | `4` |
| 5 | Escalation — stronger adjudicator (Fireworks by default; ADR 0013) | `TidyAI` router | metered $$ | `5` |

References for the model rungs:
[apple-foundation-models.md](../reference/apple-foundation-models.md) (rung 3),
[fireworks-ai.md](../reference/fireworks-ai.md) (rung 4),
[ai-provider-router.md](../conventions/ai-provider-router.md) (dispatch, retries, metering).

---

## The rungs in depth

### Rung 1 — Deterministic rules

A session whose `context_key` (or dominant token set) matches an `entity_signals` row is
attributed immediately to that signal's `client_id`/`project_id`. Zero cost, fully local.
Over time most sessions land here because the learning loop promotes confirmed patterns into
signals ([understand-layer.md](understand-layer.md) §2, §4).

- **Match:** exactly one signal (or several agreeing) resolves the session → classify,
  `produced_by_rung = 1`, `rationale = "matched <signal_type> '<signal_value>'"`.
- Conflicts resolve by provenance precedence (`user_confirmed > bootstrapped > inferred`),
  then `weight`, then `hit_count` — see [understand-layer.md](understand-layer.md) §2.3.

### Rung 2 — Lexical matching

Tokenize window titles, `url`s, and `page_snapshots.text`; score against the Productive cache
(`pd_companies.name`, `pd_projects.name`, `pd_tasks.title`). Produce a ranked candidate list
with normalized scores in `[0,1]`.

- **High-margin match:** the top candidate clears both an absolute floor **and** a margin over
  the runner-up → classify, `produced_by_rung = 2`,
  `rationale = "lexical: '<matched terms>'"`.
- The ranked shortlist (top *k*) is **carried forward** into the rung-3/4 prompts so the models
  choose among real candidates, never a raw dump (respects the 4,096-token on-device window).

### Rung 3 — On-device model (Apple Foundation Models)

Apple's ~3B on-device model with **guided generation**: a `@Generable` struct forces the
shape below from a compact session **digest** + the rung-2 shortlist. See
[apple-foundation-models.md](../reference/apple-foundation-models.md).

```swift
@Generable
struct SessionAttribution {
    @Guide(description: "Productive company id, or nil if none fits")   var clientId:  String?
    @Guide(description: "Productive project id under that client")      var projectId: String?
    @Guide(description: "Productive task id, if one clearly matches")   var taskId:    String?
    @Guide(description: "0.0–1.0 self-reported confidence")             var confidence: Double
    @Guide(description: "one clause naming the evidence")               var rationale: String
}
```

- Gated to macOS 26 + Apple Intelligence at runtime. **If unavailable, rung 3 is skipped
  entirely** and the session falls to rung 4 (subject to budget).
- Ledgered as `ai_calls.job_type = 'on_device_classify'`, `provider = 'apple'`, `cost_usd = 0`
  (metered for the on-device-share metric even though free).

### Rung 4 — Economy cloud (Fireworks AI)

The workhorse for what local rungs can't settle: low-confidence session batches, first-pass
transcript segmentation, and note drafting. OpenAI-compatible endpoint with structured
outputs; model names are **config strings**, not code (catalog churns) —
[fireworks-ai.md](../reference/fireworks-ai.md), `config.ai.models` /
[ai-provider-router.md](../conventions/ai-provider-router.md).

- Every call is gated (accepts only `GatedPayload`), metered
  (`ai_calls.job_type ∈ {session_batch, transcript_split, note_draft}`), and budget-checked
  **before dispatch**.
- For a transcript it returns time-bounded topic segments mapped to clients, each tied to
  utterance timestamps so the arithmetic is auditable
  ([suggestion-engine.md](suggestion-engine.md) meeting split).

### Rung 5 — Escalation (a stronger adjudicator; Fireworks by default per ADR 0013)

Claude adjudicates only when rung 4 earns it (conditions below). The escalation prompt
**carries the economy model's attempt** so Claude adjudicates rather than starts over.
Ledgered as `job_type = 'escalation'` (or `'calibration'` for the sampling path),
`provider = 'anthropic'`.

---

## Exact fall-through conditions

Thresholds live in config (see [§ Config](#config-keys)). Symbols: `top`/`second` = rung-2
top/runner-up scores; `conf` = a model's self-reported confidence.

| From → To | Fall through when **all** local options are exhausted, i.e. |
|---|---|
| **1 → 2** | No `entity_signals` row matches the session, **or** ≥2 signals of equal top precedence point to different clients (an unresolvable tie). |
| **2 → 3** | No candidate clears the high-margin bar: `top < accept_score` **or** `(top − second) < margin` (a *near-tie*). |
| **3 → 4** | On-device `conf < on_device_min` **or** the `@Generable` output is schema-invalid after **one** retry **or** Apple Intelligence is unavailable (rung skipped). |
| **4 → 5** | Any of: economy output schema-invalid after **one** retry; `conf < economy_min`; transcript segments' summed duration ≠ recording duration within `segment_sum_tolerance`; the result **contradicts a strong lexical prior** (`top ≥ strong_prior` yet the model picked a different client); **or** the call was selected by the [calibration sample](#calibration-sample). |
| **5 → done** | Claude's result is final for this pass; record it. |

**Definitions that bite:**
- *High-margin vs near-tie* — a match is only accepted at rung 2 when it is both good in
  absolute terms (`top ≥ accept_score`) **and** clearly ahead (`top − second ≥ margin`). Two
  plausible clients (near-tie) always fall through; guessing between clients is exactly what
  the models are for.
- *Schema-invalid-after-one-retry* — one structured-output/`@Generable` violation triggers a
  single re-ask; a second failure is a fall-through, not an error swallow
  ([ai-provider-router.md](../conventions/ai-provider-router.md)).
- *Segments not summing to duration* — for a meeting, `Σ segment_seconds` must equal the
  Fathom recording span within `segment_sum_tolerance`; otherwise the split is untrustworthy
  and Claude re-adjudicates.
- *Contradicts a strong prior* — when lexical evidence is strong (`top ≥ strong_prior`) but the
  cheap model disagrees on the client, escalate rather than trust either blindly.

At **every** boundary into a cloud rung (4 and 5) the budget check
([§ Budget](#budget-cap--local-only-g5)) runs first; a tripped cap turns "fall through to
cloud" into "stop at the best local result."

---

## Decision flow

```
                 session (screen | meeting | slack), attribution NULL
                                     │
                                     ▼
                    ┌──────────────────────────────────┐
                    │ SENSITIVITY GATE (fail-closed, G2)│
                    └──────────────┬───────────────────┘
                     sensitive     │      clear
              ┌────────────────────┘        │
              ▼                              ▼
   generic task + bland note,     ┌───────────────────────┐
   local only, is_sensitive=1     │ RUNG 1: rules         │
                                  │ entity_signals match? │
                                  └───────┬───────────────┘
                              match       │ no match / tie
                    ┌─────────────────────┘         │
                    ▼                                ▼
              classify rung=1          ┌───────────────────────────┐
                                       │ RUNG 2: lexical            │
                                       │ top≥accept & top−2nd≥margin│
                                       └───────┬────────────────────┘
                           high-margin         │ near-tie
                  ┌─────────────────────────────┘        │
                  ▼                                       ▼
            classify rung=2                    ┌────────────────────────┐
                                               │ budget OK for cloud?    │──no──┐
                                               └───────┬────────────────┘       │
                                                    yes │                        ▼
                                                        ▼            local-only + menu-bar
                                        ┌───────────────────────────┐  badge; keep best
                                        │ RUNG 3: on-device (Apple)  │  local result / unclassified
                                        │ conf≥on_device_min & valid │
                                        └───────┬────────────────────┘
                                 confident      │ low-conf / invalid×2 / AI off
                        ┌────────────────────────┘          │
                        ▼                                    ▼
                  classify rung=3          ┌───────────────────────────────┐
                                           │ RUNG 4: economy (Fireworks)    │
                                           │ valid & conf≥economy_min &     │
                                           │ segments sum & no strong-prior │
                                           │ conflict & not calibration-pick│
                                           └───────┬────────────────────────┘
                                    settles        │ else
                           ┌─────────────────────────┘        │
                           ▼                                   ▼
                     classify rung=4          ┌───────────────────────────┐
                                              │ RUNG 5: escalation         │
                                              │ (carries rung-4 attempt)   │
                                              └───────┬────────────────────┘
                                                      ▼
                                                classify rung=5 (final)
```

---

## Recording the producing rung (`produced_by_rung` + `rationale`)

Every classification stamps its origin so trust is inspectable (PLAN §7: "Every suggestion
records which rung produced it and why").

- On the **session** ([data-model.md](data-model.md) `sessions`): `produced_by_rung` (1–5),
  `confidence` (REAL), `rationale` (human clause), `classified_at`, plus resolved
  `client_id`/`project_id`/`task_id`.
- On each **suggestion** derived from it (`suggestions`): `produced_by_rung` and `rationale`
  are carried through; a meeting-segment suggestion carries the segment's rung and a timestamped
  rationale ("transcript segment 00:12:40–00:26:55").

Example `rationale` strings by rung: `1` → `matched en_account 'exampleorg'`; `2` → `lexical:
'donation page audit'`; `3` → `on-device: attendee domain + task title`; `4` → `Fireworks:
transcript 14m ClientA / 6m ClientB / 30m internal`; `5` → `Claude: reconciled segment sum`.

---

## Budget cap → local-only (G5)

Budget control spans both cloud rungs. Before dispatching **any** rung-4/5 call, the router
evaluates per-provider daily caps and a global daily cap from
`config.ai.budget`. Rung 3 is on-device (free) and is **not** gated by dollar budget, though it
is still ledgered.

- **Under cap:** dispatch, write the `ai_calls` row (tokens, `cost_usd` from the config price
  table, latency, outcome).
- **Over cap:** the request is **refused, not sent** — ledger a row with
  `outcome = 'refused_budget'`, `cost_usd = 0` — and the app drops to **local-only**: sessions
  settle at their best rung-1/2 result or stay unclassified, and the **menu bar shows a badge**
  (attention-needed) rather than failing silently ([surface-layer.md](surface-layer.md)). Work
  queued for cloud is retried after the daily window resets.

```swift
enum Budget {
    static func gate(provider: String, estCostUSD: Double, ledger: AiCallsDAO,
                     caps: BudgetCaps, day: String) -> Decision {
        let spentProvider = ledger.costToday(provider: provider, day: day)
        let spentGlobal   = ledger.costToday(day: day)
        if spentProvider + estCostUSD > (caps.daily[provider] ?? .infinity) { return .refuse }
        if spentGlobal   + estCostUSD > caps.globalDaily                    { return .refuse }
        return .dispatch                                   // caller writes the ai_calls row
    }
}
```

The budget check is evaluated **before** dispatch; there is no path that reaches a provider
without first passing it and then writing a ledger row (G5,
[guardrails.md](../guardrails.md)).

---

## Calibration sample

A decaying fraction of rung-4 outputs that would otherwise be **accepted** get a Claude second
opinion, so the build learns where the cheap tier is trustworthy (PLAN §7). Governed by
`config.ai.calibration`:

| Config key | Default | Meaning |
|---|---|---|
| `ai.calibration.initial_sample_rate` | `0.10` | Early-weeks fraction of accepted rung-4 results sent to Claude for comparison. |
| `ai.calibration.decay_after_days` | `21` | After this many days, the rate decays toward the floor. |
| `ai.calibration.floor_sample_rate` | `0.02` | Long-run minimum sampling rate. |

- Calibration picks are ledgered as `ai_calls.job_type = 'calibration'`,
  `provider = 'anthropic'`; the economy result is kept as the classification unless Claude
  disagrees materially, in which case Claude's result wins (and the disagreement informs
  routing tuning).
- Calibration is a normal cloud call: it passes the sensitivity gate and the budget check like
  any other, and it stops when a cap is tripped.
- Tuning read-out (dashboard, G5): if the economy model settles ~90%+ of jobs without
  escalation/disagreement, shift more volume down; if a job type escalates constantly, its
  prompts need work or it belongs on Claude outright.

---

## Config keys

Existing, canonical in `config.example.json`:

```json
"ai": {
  "routing":  { "session_batch": "fireworks-economy", "transcript_split": "fireworks-economy",
                "note_draft": "fireworks-economy", "escalation": "fireworks-escalation" },
  "budget":   { "daily_cap_usd": { "fireworks": 2.00, "anthropic": 2.00 },
                "global_daily_cap_usd": 3.00 },
  "calibration": { "initial_sample_rate": 0.10, "decay_after_days": 21,
                   "floor_sample_rate": 0.02 }
}
```

⚠️ **Build-time check:** the per-rung fall-through **thresholds** used above
(`accept_score`, `margin`, `on_device_min`, `economy_min`, `strong_prior`,
`segment_sum_tolerance`) are **not yet present** in `config.example.json`. They should be added
as an `ai.ladder` block before Phase 6 and tuned against real history. Proposed shape and
defaults (starting points, not verified against user data):

```json
"ai": {
  "ladder": {
    "accept_score": 0.60,          "margin": 0.15,
    "on_device_min": 0.70,         "economy_min": 0.60,
    "strong_prior": 0.75,          "segment_sum_tolerance_seconds": 60
  }
}
```

---

## Acceptance criteria (Phase 6)

- A session a rule/high-margin lexical match settles **never** issues a cloud call (assert no
  `ai_calls` row for it) — G4.
- An hour-long mixed call yields correct per-client splits whose segment durations reconcile to
  the Fathom recording span within tolerance, each with a timestamped `rationale`.
- Every rung-3/4/5 invocation writes an `ai_calls` row whose `cost_usd` reconciles against the
  provider dashboard; on-device calls appear with `cost_usd = 0`.
- Tripping a daily cap refuses further cloud calls (`outcome = 'refused_budget'`), shows the
  menu-bar badge, and leaves classification at the best local rung — no silent failure (G5).
- A seeded schema-invalid economy output escalates to Claude after exactly one retry; a
  strong-prior conflict escalates; a clean high-confidence economy result does **not**.
