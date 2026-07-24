# Phase 6 — Intelligence

The phase that turns reconstructed sessions into cloud-quality, budgeted, auditable suggestions:
the fail-closed sensitivity gate, the on-device model rung, the metered provider router, the
Fireworks economy tier, Claude escalation, transcript splitting, nudges, learning-loop promotions,
and the dashboard's AI-overhead panel. Implements [PLAN §11 Phase 6](../../PLAN.md) (and §7 rungs 3–5).

**Related:** [docs index](../README.md) · [PLAN.md §11](../../PLAN.md) ·
[classification-ladder.md](../architecture/classification-ladder.md) ·
[ai-provider-router.md](../conventions/ai-provider-router.md) ·
[fireworks-ai.md](../reference/fireworks-ai.md) ·
[apple-foundation-models.md](../reference/apple-foundation-models.md) ·
[guardrails.md](../guardrails.md) · [data-model.md](../architecture/data-model.md) ·
[understand-layer.md](../architecture/understand-layer.md) ·
[suggestion-engine.md](../architecture/suggestion-engine.md)

---


## Status: as built (2026-07-24)

> ✅ **Logic complete + unit-tested** (117 tests total). Shipped: `v1-ai` migration + records/DAOs,
> the metered `AIRouter` (gate → route → budget → outbound → call → ledger; G2 + G5),
> `BudgetPolicy`, `ModelCost`, `OutboundPayloadRecorder`, Fireworks/Anthropic providers, the Apple
> on-device provider wired to the **real Foundation Models API** (runtime-gated), `NoteDrafter`,
> `NudgeEngine`, and the AI-overhead `DashboardBuilder` + CSV. Full write-up:
> [../retrospectives/phase-6.md](../retrospectives/phase-6.md).
>
> ⚠️ **Deferred/thin (flagged):** end-to-end transcript-split → `meeting_segment` suggestions,
> on-device `@Generable` guided generation, and calibration sampling are scaffolded but not fully
> wired. Live cloud/on-device calls need keys + macOS 26 Apple Intelligence; the router/gate/budget/
> ledger/parsing are fully tested with fakes/fixtures. The Anthropic structured-output request shape
> is a build-time check.

**Ships:** the on-device rung (3), the cloud rungs (4–5), the gate, the router, the ledger, nudges,
and the dashboard. · **Prereq:** Phases 0–5 complete (capture, mirror, meetings, Slack, recap +
rungs 1–2). · **Targets touched:** `TidyUnderstand`, `TidyAI`, `TidySuggest`, `TidySurface`,
`TidyStore`, `App/`. · **Guardrails in force:** **G2** (gate fails closed), **G4** (local-first
ladder), **G5** (metered + capped cloud), **G6** (Keychain secrets). · **Last reviewed:** 2026-07-23

---

## 1. What this phase delivers

By the end of Phase 6 the classification ladder is complete and every suggestion carries a rung and
a rationale. Build in this order — **the gate ships before or with the first cloud call, and the
router + ledger ship WITH the first cloud call, never after**:

| # | Deliverable | Lives in | Ladder rung / role |
|---|---|---|---|
| 1 | **Sensitivity gate** → `GatedPayload` + outbound-payload log | `TidyUnderstand` / `TidyAI` | pre-cloud gate (G2) |
| 2 | **On-device rung** with guided generation | `TidyAI` | rung 3 (Apple Foundation Models) |
| 3 | **Provider router + usage ledger** (`ai_calls`) + budget caps | `TidyAI` | routing + metering (G4, G5) |
| 4 | **Economy tier** on Fireworks with batching | `TidyAI` | rung 4 (session batch, note draft) |
| 5 | **Claude escalation + calibration sampling** | `TidyAI` | rung 5 (adjudication) |
| 6 | **Transcript splitting** (meeting split → per-client segments) | `TidyAI` + `TidySuggest` | rung 4 job `transcript_split` |
| 7 | **Nudges** (`nudges` table) | `TidySurface` + `App/` | live surface |
| 8 | **Learning-loop promotions** wired into rungs 3–5 and nudges | `TidyUnderstand` | few-shot + threshold tuning |
| 9 | **Dashboard** incl. AI-overhead panel + CSV export | `TidySurface` | metrics |

Everything cloud passes two hard gates at a single metered call site: the **sensitivity gate**
(G2) then the **budget check** (G5). There is no code path to a provider that skips either — see
[classification-ladder.md](../architecture/classification-ladder.md) and
[ai-provider-router.md](../conventions/ai-provider-router.md).

## 2. Data model additions

Phase 6 introduces exactly two tables from
[data-model.md](../architecture/data-model.md#ai-ledger--nudges-phase-6): `ai_calls` and `nudges`.
Register them as a **new** migration (never edit a shipped one — CLAUDE.md DoD); suggested name
`v1-intelligence`. The DDL below is the canonical shape — do not invent columns.

```sql
CREATE TABLE ai_calls (
    id            INTEGER PRIMARY KEY,
    occurred_at   INTEGER NOT NULL,
    job_type      TEXT NOT NULL,   -- 'session_batch'|'transcript_split'|'note_draft'|
                                   -- 'calibration'|'escalation'|'on_device_classify'
    provider      TEXT NOT NULL,   -- 'apple'|'fireworks'|'anthropic'
    model         TEXT NOT NULL,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0,   -- computed from config price table
    latency_ms    INTEGER,
    outcome       TEXT NOT NULL,   -- 'ok'|'retried'|'escalated'|'error'|
                                   -- 'refused_budget'|'refused_sensitive'
    request_ref   TEXT,            -- what it classified (session ids / meeting id)
    error         TEXT
);
CREATE INDEX idx_aicalls_occurred ON ai_calls(occurred_at);
CREATE INDEX idx_aicalls_provider ON ai_calls(provider, model);

CREATE TABLE nudges (
    id            INTEGER PRIMARY KEY,
    fired_at      INTEGER NOT NULL,
    context_key   TEXT NOT NULL,
    client_id     TEXT REFERENCES pd_companies(id),
    session_id    INTEGER REFERENCES sessions(id),
    suggestion_id INTEGER REFERENCES suggestions(id),
    outcome       TEXT,            -- 'accepted'|'snoozed'|'dismissed'|'ignored'
    responded_at  INTEGER
);
CREATE INDEX idx_nudges_fired   ON nudges(fired_at);
CREATE INDEX idx_nudges_context ON nudges(context_key);
```

`ai_calls` is a **kept-forever** distilled artifact (guardrail G9 retention table) — it is the AI
overhead ledger and must survive the 90-day purge. `nudges` also persists. Timestamps are
`INTEGER` epoch **seconds UTC**; `cost_usd` is a `REAL` dollar figure computed at write time from
`config.ai.prices_usd_per_mtok` (see §5). GRDB records: `AiCall`, `Nudge`
(PascalCase-singular of the table names).

Sessions written by rungs 3–5 set `sessions.produced_by_rung` ∈ `3|4|5`, `sessions.confidence`,
`sessions.rationale`, `sessions.classified_at`, and (from the gate) `sessions.is_sensitive`.
Suggestions written this phase reuse the `suggestions` shape from Phase 5 with `kind` ∈
`'session'|'pool'|'meeting_segment'|'new_task'` and `produced_by_rung` set accordingly.

## 3. Configuration used this phase

All from [`config.example.json`](../../config.example.json) — non-secret only; keys/tokens live in
the Keychain via `SecretStore` (G6). Model slugs, endpoints, prices, and job→model routing are
**config, not code** (PLAN §12 catalog churn).

```json
"ai": {
  "enabled": true,
  "on_device": { "enabled": true },
  "routing": {
    "session_batch":    "fireworks-economy",
    "transcript_split": "fireworks-economy",
    "note_draft":       "fireworks-economy",
    "escalation":       "anthropic-claude"
  },
  "models": {
    "fireworks-economy": { "provider": "fireworks", "model": "accounts/fireworks/models/kimi-k2p6",
                           "endpoint": "https://api.fireworks.ai/inference/v1" },
    "anthropic-claude":  { "provider": "anthropic", "model": "claude-opus-4-8",
                           "endpoint": "https://api.anthropic.com/v1" }
  },
  "prices_usd_per_mtok": {
    "accounts/fireworks/models/kimi-k2p6": { "input": 0.95, "output": 4.00 },
    "claude-opus-4-8": { "input": null, "output": null }
  },
  "budget": {
    "daily_cap_usd": { "fireworks": 2.00, "anthropic": 2.00 },
    "global_daily_cap_usd": 3.00
  },
  "calibration": { "initial_sample_rate": 0.10, "decay_after_days": 21, "floor_sample_rate": 0.02 }
},
"nudges": {
  "enabled": true, "sustained_block_minutes": 25, "confidence_threshold": 0.7,
  "daily_cap": 5, "quiet_hours": { "start": "18:00", "end": "09:00" }
}
```

> ⚠️ **Build-time check: Claude price.** `claude-opus-4-8` input/output prices are `null` until
> set from the Anthropic account. Reference figure from Anthropic pricing: **$5.00 / M input,
> $25.00 / M output** for Opus 4.8 — confirm live at <https://platform.claude.com/docs/en/pricing>
> when the key is created, then fill `ai.prices_usd_per_mtok["claude-opus-4-8"]` so escalation
> costs land in `ai_calls`. Until set, an escalation with `null` price must record `cost_usd = 0`
> and flag the gap (do not silently drop the ledger row).

## 4. The sensitivity gate (G2 — ships first)

The gate is specified in [understand-layer.md §3](../architecture/understand-layer.md). Phase 6
adds the **enforcement seam** the cloud clients depend on and the log the acceptance test reads.

- **Type-level enforcement.** `TidyAI` cloud clients (`FireworksProvider`, `AnthropicProvider`)
  accept **only** a `GatedPayload` — a value the `SensitivityGate` alone can mint (module-map
  `SensitivityGate` seam). There is no constructor for a cloud request body that bypasses the gate.
- **When it runs.** Before rung 3 (on-device), before rung 4/5 (cloud), and before any note draft.
  On `.sensitive`: set `sessions.is_sensitive = 1`, do **not** call rungs 3–5, fall back to the
  generic task + bland note, and never place the content in an outbound payload.
- **Outbound-payload log.** A local, `DEBUG`/opt-in log at the single metered call site records the
  **exact bytes** sent to each cloud provider, with `Authorization` / `x-api-key` headers stripped
  (G6). This is what the Phase 6 acceptance test queries to prove a seeded sensitive phrase appears
  in **no** payload.

```swift
enum GateDecision { case clear(GatedPayload), sensitive }

/// The ONLY producer of GatedPayload. Cloud clients take GatedPayload, nothing else.
struct KeywordSensitivityGate: SensitivityGate {
    let keywords: [String]      // config.sensitivity.keywords + flagged_terms (lowercased)
    let flaggedPeople: Set<String>

    func gate(digest: SessionDigest, participants: [String]) -> GateDecision {
        let hay = digest.searchableText.lowercased()
        let tripped = keywords.contains { hay.contains($0) }
            || participants.contains { flaggedPeople.contains($0.lowercased()) }
        // Uncertainty resolves to sensitive (fail closed).
        return tripped ? .sensitive : .clear(GatedPayload(digest: digest))
    }
}
```

```swift
/// Every cloud send passes through here — gate, then budget, then log, then dispatch.
func sendToCloud(_ payload: GatedPayload, job: JobType, via provider: AIProvider) async throws {
    guard budget.allows(provider: provider.name, estimated: payload.estimatedCostUSD) else {
        try ledger.record(refusedBudget(job: job, provider: provider.name))   // outcome='refused_budget'
        appMode.dropToLocalOnly()                                             // menu-bar badge (G5)
        return
    }
    outboundPayloadLog.record(provider.name, bytes: payload.wireBytes)        // DEBUG/opt-in, headers stripped
    // ...dispatch + ledger row (see §5)
}
```

Sensitive content that never reaches the gate's `.clear` branch simply has no `wireBytes` to log —
which is exactly why the test passes. See [guardrails.md G2](../guardrails.md#g2--the-sensitivity-gate-fails-closed).

## 5. Provider router + usage ledger (ships WITH the first cloud call)

The router resolves a `job_type` → logical model (`routing`) → concrete slug + endpoint + price
(`models`, `prices_usd_per_mtok`), short-circuits at the first confident rung (G4), and writes
**exactly one `ai_calls` row per call** at a single metered call site (G5). Full mechanics:
[ai-provider-router.md](../conventions/ai-provider-router.md).

```swift
protocol AIProvider {                          // TidyCore seam
    var name: String { get }                   // 'apple' | 'fireworks' | 'anthropic'
    func classify(_ p: GatedPayload, job: JobType) async throws -> AIResult
}
```

**Cost is computed from the config price table**, so re-pricing is a `config.json` edit and never
touches Swift; historical rows keep their computed `cost_usd`:

```swift
func costUSD(inputTokens: Int, outputTokens: Int, price: ModelPrice) -> Double {
    (Double(inputTokens)  / 1_000_000 * price.input) +
    (Double(outputTokens) / 1_000_000 * price.output)
}
```

Mapping provider `usage` onto the ledger (same for Fireworks and Anthropic):

| Provider `usage` field | `ai_calls` column |
|---|---|
| `prompt_tokens` (Fireworks) / `input_tokens` (Anthropic) | `input_tokens` |
| `completion_tokens` (Fireworks) / `output_tokens` (Anthropic) | `output_tokens` |
| — computed | `cost_usd` · — measured | `latency_ms` |
| set by call site | `provider`, `model`, `job_type`, `outcome`, `request_ref` |

**Budget check runs BEFORE dispatch.** Sum today's `ai_calls.cost_usd` for the provider (and across
all providers for the global cap); if this call's estimate would exceed either cap, refuse it —
write a row with `outcome='refused_budget'` (zero tokens), skip the network call, and drop the app
to **local-only** (ladder stops at rung 2) with the attention-needed menu-bar badge. Never a silent
failure, never an uncapped spend. See [fireworks-ai.md §Budget caps](../reference/fireworks-ai.md#budget-caps--local-only-g5)
and [guardrails.md G5](../guardrails.md#g5--every-cloud-ai-call-is-metered-and-capped).

`ai_calls.outcome` values, by meaning: `ok` (settled), `retried` (transient error, re-sent),
`escalated` (rung 4 handed to rung 5), `error` (unrecovered), `refused_budget` (cap tripped, not
sent), `refused_sensitive` (gate tripped, not sent — recorded for auditability, zero tokens).

## 6. On-device rung (rung 3) — guided generation

Full contract in [apple-foundation-models.md](../reference/apple-foundation-models.md). Runs when
rungs 1–2 fell through **and** `onDeviceAvailability() == .ready` **and**
`config.ai.on_device.enabled`. Uses a `@Generable` struct so decoding is constrained to
`{clientId, projectId, taskId?, confidence, rationale}` — the same shape rung 4 returns, so
downstream is rung-agnostic. One session per call (the ~4,096-token window forbids batching); send a
distilled digest plus only the rung-2 shortlist, never raw `page_snapshots`/transcripts.

Writes to `sessions`: `client_id`, `project_id`, `task_id`, `confidence`, `rationale`,
`produced_by_rung = 3`, `classified_at`. Metered too — one `ai_calls` row per call:

| Column | Value |
|---|---|
| `provider` | `'apple'` · `model` | `'apple-on-device'` (⚠️ build-time check — no public slug) |
| `job_type` | `'on_device_classify'` · `cost_usd` | `0` (free) |
| `input_tokens` / `output_tokens` | best-effort or `0` (framework may not expose counts) |
| `outcome` | `'ok'` \| `'error'` · `request_ref` | the session id |

No budget cap (cost is zero), no `refused_budget` path. **Falls through to rung 4** (not an
escalation to Claude) when the model is unavailable, confidence is below the router threshold, or
the result contradicts a strong lexical prior. A skipped rung 3 is normal — surface capability
status once in `doctor`, do not nag.

## 7. Economy tier — Fireworks (rung 4) with batching

Full endpoint/auth/schema reference: [fireworks-ai.md](../reference/fireworks-ai.md). Rung 4 is the
workhorse for three `job_type`s: `session_batch`, `transcript_split`, `note_draft`.

- **Endpoint:** `POST /chat/completions` (OpenAI-compatible; path is relative to the base — do not
  repeat `/inference/v1`), base `https://api.fireworks.ai/inference/v1`, header
  `Authorization: Bearer <FIREWORKS_API_KEY>` (Keychain, G6). Full URL:
  `https://api.fireworks.ai/inference/v1/chat/completions`.
- **Structured outputs:** `response_format: {type:"json_schema", json_schema:{name,schema}}` forces
  the classification struct. Include the schema in **both** the prompt text and `response_format`
  for best adherence, and **validate the parsed JSON** — a schema-invalid response after one retry
  is an escalation trigger to rung 5.
- **Batching (`session_batch`):** accumulate fall-through sessions rungs 1–3 couldn't settle and
  classify them in one call; each session carries a distilled digest + its rung-2 candidate
  shortlist. Cap batches to a few dozen sessions (a digest is ~50–150 tokens; well under the 262K
  window) so one bad response doesn't sink a day. Already-settled sessions are filtered out before
  the call — never re-pay for a rung-1/2 result (G4). Re-running a batch upserts classifications.
- **`note_draft`:** post-gate note generation. Sensitive sessions never reach here — they got the
  bland generic note at the gate. Keep `max_tokens` tight (output is 4× input price).

Response `usage` → `ai_calls` per §5; `cost_usd` example: `512/1e6*0.95 + 96/1e6*4.00 = $0.00087`.

## 8. Transcript splitting (rung 4 job `transcript_split`)

An hour-long mixed call is the headline acceptance case. One `transcript_split` call **per meeting**
returns time-bounded, per-client segments tied to `transcript_utterances.start_seconds` offsets;
`TidySuggest`'s meeting splitter turns those into `suggestions` (see
[suggestion-engine.md](../architecture/suggestion-engine.md) "Meeting splitting").

Duration is **Fathom recording ground truth** — `meetings.duration_seconds` (from
`recording_start`/`recording_end`), not the calendar slot. Each segment maps utterance offsets to a
`client_id` + minutes; the remainder is internal.

### Example request (`transcript_split`)

```json
{
  "model": "accounts/fireworks/models/kimi-k2p6",
  "temperature": 0.2, "max_tokens": 1024,
  "messages": [
    { "role": "system",
      "content": "Split a meeting transcript into time-bounded segments, each mapped to ONE Productive client from the candidates (or 'internal'). Segments must not overlap and must cover the full recording. Return JSON matching the schema." },
    { "role": "user",
      "content": "Recording: 3660s (61m). Candidates: [{client_id:\"c_017\",name:\"Example Org\"},{client_id:\"c_051\",name:\"Acme Fund\"}]. Utterances (start_s | speaker | text): 0|Nick|... 760|Nick|Example Org donation page... 1620|Sara|Acme audit findings... 2020|Nick|internal weekly sync ...\n\nSchema: {segments:[{start_seconds,end_seconds,client_id,rationale}]}" }
  ],
  "response_format": { "type": "json_schema", "json_schema": {
    "name": "transcript_segments",
    "schema": { "type":"object","additionalProperties":false,
      "required":["segments"],
      "properties": { "segments": { "type":"array","items": {
        "type":"object","additionalProperties":false,
        "required":["start_seconds","end_seconds","client_id","rationale"],
        "properties": {
          "start_seconds": {"type":"number"}, "end_seconds": {"type":"number"},
          "client_id": {"type":"string"}, "rationale": {"type":"string"} } } } } } }
}
```

### Example response

```json
{ "model": "accounts/fireworks/models/kimi-k2p6",
  "choices": [ { "finish_reason":"stop", "message": { "role":"assistant",
    "content": "{\"segments\":[{\"start_seconds\":760,\"end_seconds\":1620,\"client_id\":\"c_017\",\"rationale\":\"00:12:40–00:27:00 Example Org donation page\"},{\"start_seconds\":1620,\"end_seconds\":2020,\"client_id\":\"c_051\",\"rationale\":\"00:27:00–00:33:40 Acme audit findings\"},{\"start_seconds\":2020,\"end_seconds\":3660,\"client_id\":\"internal\",\"rationale\":\"remainder: weekly sync\"}]}" } } ],
  "usage": { "prompt_tokens": 4120, "completion_tokens": 180, "total_tokens": 4300 } }
}
```

`TidySuggest` maps that to three suggestions with `kind='meeting_segment'`,
`source_refs_json = {"meeting_id":"…","seg":<index>}`, and per-client minutes rounded to 15 with the
round-up bias (`is_rounded_up = 1` where rounding occurred — e.g. Acme's ~6.7 min → 15 min). Each
suggestion's `rationale` carries the segment timestamp so the math is auditable.

**Reconciliation → escalation.** If the returned segments don't cover / sum to
`meetings.duration_seconds` (overlap, gap, or total ≠ recording), or a segment contradicts a strong
lexical prior, the split is handed to rung 5 (Claude) with the rung-4 attempt in the prompt; the
`ai_calls` row for the rung-4 call gets `outcome='escalated'`.

## 9. Claude escalation (rung 5) + calibration sampling

Claude adjudicates rung-4 output rather than starting over — the cheaper model's attempt rides along
in the prompt. Triggers (PLAN §7): schema-invalid after one retry, self-reported confidence below
threshold, transcript segments that don't reconcile, or a result that contradicts a strong lexical
prior. Plus a decaying **calibration sample**: `config.ai.calibration.initial_sample_rate` (0.10) of
rung-4 outputs get a Claude second opinion; the rate decays after `decay_after_days` (21) toward
`floor_sample_rate` (0.02). Calibration and escalation write distinct `job_type`s (`calibration`,
`escalation`) so the dashboard can separate "measuring the cheap tier" from "rescuing it".

- **Endpoint:** `POST /messages` (path relative to the base — do not repeat `/v1`), base
  `https://api.anthropic.com/v1`, headers `x-api-key: <ANTHROPIC_API_KEY>` (Keychain, G6) and
  `anthropic-version: 2023-06-01`. Full URL: `https://api.anthropic.com/v1/messages`.
- **Model:** `claude-opus-4-8` (config `ai.models.anthropic-claude.model`).
- **Structured output:** ⚠️ **Build-time check** — confirm Anthropic's *current* structured-output
  request shape when the key is created; the field names below (`output_config.format`,
  `output_config.effort`, prefill behavior, `budget_tokens` handling) are **unverified** and may
  differ (structured output may instead go through `tools`/`tool_choice`, and extended-thinking
  depth through `thinking.budget_tokens`). Intended behavior: force the same classification /
  segment struct rung 4 uses, and keep adjudication depth bounded.

```http
POST /v1/messages HTTP/1.1
Host: api.anthropic.com
x-api-key: sk-ant-XXXXXXXX
anthropic-version: 2023-06-01
content-type: application/json
```

```json
{
  "model": "claude-opus-4-8",
  "max_tokens": 1024,
  "output_config": {
    "effort": "low",
    "format": { "type": "json_schema", "schema": {
      "type":"object","additionalProperties":false,
      "required":["client_id","project_id","confidence","rationale"],
      "properties": {
        "client_id": {"type":"string"}, "project_id": {"type":"string"},
        "task_id": {"type":["string","null"]},
        "confidence": {"type":"number"}, "rationale": {"type":"string"} } } }
  },
  "messages": [
    { "role": "user",
      "content": "Adjudicate a low-confidence attribution. Session digest: 'chrome — exampleorg.engagingnetworks.app donation editor; 22m'. Candidates: [{client_id:\"c_017\",name:\"Example Org\"},{client_id:\"c_051\",name:\"Acme Fund\"}]. The economy model returned {client_id:\"c_051\",confidence:0.55}, which contradicts the EN-account signal 'exampleorg'. Return the corrected attribution as JSON." }
  ]
}
```

Read `usage.input_tokens` / `usage.output_tokens` into the ledger (`provider='anthropic'`,
`model='claude-opus-4-8'`, `job_type='escalation'` or `'calibration'`, `cost_usd` from the price
table). Handle `stop_reason == "refusal"` — a refused adjudication is `outcome='error'`, not a crash
(guard before reading `content`). Payload is the same post-gate `GatedPayload`; the sensitivity gate
applies identically to Anthropic and Fireworks (PLAN §12).

## 10. Nudges

Fire a live notification only when a sustained block classifies confidently to one client and
nothing is logged there yet (gap analysis vs. `pd_time_entries`). Config in `config.ai`/`config.nudges`.

**Fire conditions (all must hold):**
- Block ≥ `nudges.sustained_block_minutes` (25) on one `context_key` resolving to one `client_id`.
- `confidence` ≥ the context's **effective** threshold (base `nudges.confidence_threshold` 0.7,
  raised per dismissals — see §11).
- No `pd_time_entries` logged for that client/day yet.
- **Not** during a meeting or inside a `calendar_events` window; outside `nudges.quiet_hours`.
- Today's fired count `< nudges.daily_cap` (5).

On fire, insert a `nudges` row (`fired_at`, `context_key`, `client_id`, `session_id`,
`suggestion_id`, `outcome = NULL`). The notification offers **accept** (marks it, copies the note →
`outcome='accepted'`, `responded_at`) or **snooze to recap** (`outcome='snoozed'`). No response by
recap time → `outcome='ignored'`. A dismiss → `outcome='dismissed'`. Ignoring nudges costs nothing —
everything a nudge would say waits in the recap regardless.

Daily-cap check (local-day epoch bounds):

```sql
SELECT COUNT(*) FROM nudges WHERE fired_at >= :day_start AND fired_at < :day_end;
-- fire only if the count is < config.nudges.daily_cap
```

## 11. Learning-loop promotions

The loop is deterministic bookkeeping (no training, no embeddings — PLAN §7); Phase 6 wires it into
the AI rungs and nudges. Base mechanics: [understand-layer.md §4](../architecture/understand-layer.md#4-learning-loop-rules--examples-no-training-no-embeddings-in-v1).

- **Promotions → rung 1.** A reassignment (`decisions.action='reassign'`) upserts/strengthens the
  responsible `entity_signals` row with `provenance='user_confirmed'`; reassign the same signal
  twice and the next same-context session classifies at **rung 1** (free), never reaching a model.
  A rising "share resolved on-device/free" on the dashboard is the loop working (G4).
- **Few-shot injection.** The last N `decisions` for a context ride along as few-shot examples in
  the rung 3 and rung 4 prompts, biasing the models toward demonstrated choices. Drop few-shots
  first when the on-device 4,096-token window is tight (candidates outrank examples).
- **Dismissed-nudge threshold.** Each `nudges.outcome='dismissed'` for a `context_key` raises that
  context's **effective** nudge threshold, so the same context must classify *more* confidently
  before nudging again — that is why acceptance #4's "stop poking dismissed contexts" holds. A
  concrete rule: `effective = base + step * dismiss_count`, clamped ≤ 0.95.

## 12. Dashboard incl. AI-overhead panel

Local-only, weekly, no targets ([surface-layer.md](../architecture/surface-layer.md)). Four
numbers + one chart from `daily_rollups`, plus the **AI-overhead panel** driven by `ai_calls`:
month-to-date spend, cost by job type, escalation rate ("is the cheap tier earning its keep"),
on-device share, and a **CSV export** for internal accounting. `daily_rollups.ai_cost_usd` is
written per day from the day's `ai_calls`.

```sql
-- Month-to-date AI spend (epoch of month start in the user's local zone):
SELECT COALESCE(SUM(cost_usd), 0) FROM ai_calls WHERE occurred_at >= :month_start;

-- Cost by job type:
SELECT job_type, COALESCE(SUM(cost_usd),0) AS usd, COUNT(*) AS n
FROM ai_calls WHERE occurred_at >= :month_start GROUP BY job_type ORDER BY usd DESC;

-- Escalation rate = rung-5 escalations / rung-4 jobs settled:
SELECT
  CAST(SUM(job_type = 'escalation') AS REAL)
  / NULLIF(SUM(job_type IN ('session_batch','transcript_split','note_draft')), 0) AS escalation_rate
FROM ai_calls WHERE occurred_at >= :month_start;

-- On-device (free) share of all classify jobs:
SELECT
  CAST(SUM(provider = 'apple') AS REAL)
  / NULLIF(SUM(job_type IN ('on_device_classify','session_batch','escalation')), 0) AS on_device_share
FROM ai_calls WHERE occurred_at >= :month_start;
```

CSV export columns mirror `ai_calls`: `occurred_at, job_type, provider, model, input_tokens,
output_tokens, cost_usd, latency_ms, outcome, request_ref`.

## 13. File & function manifest

Regenerate the Xcode project (`make generate`) after adding files. All I/O behind protocols for
fixture-based tests (no live network).

| Target | File | Key types / functions |
|---|---|---|
| `TidyCore` | `AIProvider.swift` | `protocol AIProvider`, `JobType`, `AIResult`, `ModelPrice`, `GatedPayload` |
| `TidyUnderstand` | `SensitivityGate.swift` | `KeywordSensitivityGate`, `GateDecision`, few-shot builder |
| `TidyAI` | `AIRouter.swift` | `route(job:)`, short-circuit, single metered call site |
| `TidyAI` | `AppleOnDeviceProvider.swift` | `@Generable SessionClassification`, `classifyOnDevice`, availability gate |
| `TidyAI` | `FireworksProvider.swift` | chat/completions client, `json_schema`, batch encoder |
| `TidyAI` | `AnthropicProvider.swift` | `/v1/messages` client, `output_config.format`, refusal handling |
| `TidyAI` | `UsageLedger.swift` | `record(AiCall)`, `costUSD(...)`, `usage → ai_calls` mapping |
| `TidyAI` | `BudgetGuard.swift` | pre-dispatch cap check, `dropToLocalOnly()`, `refused_budget` row |
| `TidyAI` | `OutboundPayloadLog.swift` | DEBUG/opt-in byte log, header stripping (G2 test hook) |
| `TidyAI` | `CalibrationSampler.swift` | decaying sample rate, `calibration` job dispatch |
| `TidySuggest` | `MeetingSplitter.swift` | consume `transcript_split`, reconcile vs. `duration_seconds`, emit `meeting_segment` suggestions |
| `TidySurface` | `NudgePresenter.swift` | fire conditions, cap check, `nudges` row, accept/snooze/dismiss |
| `TidySurface` | `DashboardView.swift` + `AIOverheadPanel.swift` | the four metrics, AI panel, CSV export |
| `TidyStore` | `AiCallDAO.swift`, `NudgeDAO.swift`, `Migrations+Intelligence.swift` | `v1-intelligence` migration, ledger/nudge queries, `daily_rollups.ai_cost_usd` update |
| `App/` | pipeline wiring | inject router into `TidyUnderstand`/`TidySuggest`, nudge scheduler, budget badge in menu bar |

## 14. Acceptance criteria (PLAN §11 — verifiable without reading Swift)

1. **Per-client meeting split.** An hour-long mixed Fathom call yields correct per-client
   `suggestions` (`kind='meeting_segment'`) whose minutes sum to the **Fathom recording** duration
   (`meetings.duration_seconds`), each with a **timestamped rationale** (e.g. `00:12:40–00:27:00`).
   Rounded segments carry `is_rounded_up = 1`.
2. **Sensitivity gate proven.** A seeded sensitive phrase in a fixture transcript sets
   `sessions.is_sensitive = 1`, produces a **generic** suggestion with a bland note, and appears in
   **no** entry of the outbound-payload log for either provider — assert the phrase is absent from
   every logged `wireBytes`.
3. **Ledger reconciles.** Every cloud call has exactly one `ai_calls` row with `input_tokens` /
   `output_tokens` and a `cost_usd` computed from the price table; summed `cost_usd` for a provider
   over a window matches that provider's billing dashboard (Fireworks; Anthropic once its price is
   set). On-device calls appear with `provider='apple'`, `cost_usd = 0`.
4. **Nudges bounded + learn.** No more than `nudges.daily_cap` `nudges` rows fire in a local day;
   after a `nudges.outcome='dismissed'` for a `context_key`, that context does not re-nudge until it
   clears a raised effective threshold.

## 15. Testing & guardrail tests

Live in `Packages/TidyKit/Tests/` with recorded fixtures + in-memory GRDB
([testing-strategy](../build/testing-strategy.md)). At minimum:

- **G2 seed test** (acceptance #2): fixture transcript with a planted term → assert
  `is_sensitive=1`, generic fallback, phrase absent from `OutboundPayloadLog`.
- **G5 cap test**: seed `ai_calls` up to `daily_cap_usd` → next call refused with
  `outcome='refused_budget'`, zero tokens, no network dispatch, app in local-only.
- **G4 short-circuit test**: a session a rule/high-margin lexical match settles never produces a
  rung 3/4/5 `ai_calls` row.
- **Ledger cost test**: known `usage` → assert `cost_usd` equals the price-table computation.
- **Split reconciliation test**: segments that don't sum to `duration_seconds` → the rung-4 row is
  `outcome='escalated'` and rung 5 is invoked with the attempt in the prompt.
- **Nudge cap test** (acceptance #4): cap boundary + dismiss-then-suppress.

## 16. Gotchas

- **Order is load-bearing.** Ship the gate and the router+ledger **with** the first cloud call — a
  cloud call with no ledger row or no gate is a G2/G5 violation, not a follow-up task.
- **`json_schema` silently downgraded.** Some proxies coerce Fireworks `json_schema` to
  `json_object` (no enforcement) — always validate the parsed JSON; a validation failure is a retry,
  then an escalation ([fireworks-ai.md](../reference/fireworks-ai.md)).
- **Slug drift.** A Fireworks 404 / "model not found" means the catalog moved — the fix is a
  `config.json` slug edit, not code; keep GLM-class fallbacks in mind (PLAN §12).
- **Opus 4.8 quirks.** ⚠️ Build-time check (see §9): the exact structured-output request shape is
  unverified. Regardless of shape, guard `stop_reason == "refusal"` before reading `content`.
- **Never log a key.** The outbound-payload log strips `Authorization` / `x-api-key`; the logger
  redacts token-shaped strings (G6).
- **On-device is a step down, not an escalation.** Rung-3 failure/unavailability falls through to
  rung 4, never straight to Claude.
- **Sensitive never re-exposed.** A session with `is_sensitive=1` must never subsequently reach
  rung 4/5 — carry the flag into the suggestion (`suggestions.is_sensitive`).
- **Reconcile the ledger to the dashboard.** If a provider reports a different `usage` shape (e.g.
  cached-prompt tokens), record what it returns and true it up — Phase 6 acceptance requires the
  ledger to match the provider's billing (fireworks-ai.md).
