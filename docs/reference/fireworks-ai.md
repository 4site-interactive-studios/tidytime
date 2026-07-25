# Fireworks AI — economy cloud tier (ladder rung 4)

The cloud workhorse: an OpenAI-compatible endpoint serving open-weight models (Kimi K2.6,
GLM-class) with schema-enforced structured outputs. Used for low-confidence session batches,
transcript segmentation, and note drafting — everything the local rungs (1–3) can't settle.

**Related:** [docs index](../README.md) · [PLAN.md §7](../../PLAN.md) ·
[apple-foundation-models.md](apple-foundation-models.md) ·
[classification-ladder.md](../architecture/classification-ladder.md) ·
[ai-provider-router.md](../conventions/ai-provider-router.md) ·
[guardrails.md](../guardrails.md)

---

**Status:** active · **Base URL:** `https://api.fireworks.ai/inference/v1` ·
**Auth:** `Authorization: Bearer <FIREWORKS_API_KEY>` (Keychain, guardrail
[G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)) ·
**Source:** <https://docs.fireworks.ai/structured-responses/structured-response-formatting>,
<https://docs.fireworks.ai/api-reference/post-chatcompletions>, <https://fireworks.ai/pricing> ·
**Last verified:** 2026-07-23

---

## Why this rung exists

At $0.95 / M input tokens the app can be liberal: a full day of transcripts plus low-confidence
session batches costs cents, so more content gets cloud-quality attribution without spend anxiety.
Fireworks is OpenAI-wire-compatible, so one client library covers every model and swapping model
slugs is a config edit, not a code change (see [Models are config](#models-are-config-not-code)).

This rung lives entirely in **`TidyAI`** (the only target allowed to make cloud calls), behind the
`AIProvider` protocol as `FireworksProvider`
([module-map](../architecture/module-map.md#protocol-seams-the-extension-points)). Two hard gates
sit in front of every call:

1. **Sensitivity gate** (G2) — the payload must be a post-gate `GatedPayload`; tripped content
   never reaches Fireworks. See [understand-layer.md](../architecture/understand-layer.md).
2. **Budget check** (G5) — evaluated **before** dispatch; over-cap calls are refused, logged to
   `ai_calls` with `outcome='refused_budget'`, and the app drops to local-only.

---

## Endpoint & auth

| | |
|---|---|
| Base URL | `https://api.fireworks.ai/inference/v1` |
| Path | `POST /chat/completions` (OpenAI-compatible) |
| Auth header | `Authorization: Bearer <FIREWORKS_API_KEY>` |
| Content type | `application/json` |
| Key storage | macOS Keychain via `SecretStore` — never in `config.json`, logs, or the DB (G6) |

```http
POST /inference/v1/chat/completions HTTP/1.1
Host: api.fireworks.ai
Authorization: Bearer fw_XXXXXXXXXXXXXXXXXXXXXXXX
Content-Type: application/json
```

Because the wire format is OpenAI's, the same request/response structs serve Fireworks today and
any other OpenAI-compatible economy provider later.

---

## Model: Kimi K2.6

| Field | Value |
|---|---|
| Slug (config `ai.models.fireworks-economy.model`) | `accounts/fireworks/models/kimi-k2p6` ⚠️ **Build-time check** |
| Input price | **$0.95 / M tokens** |
| Output price | **$4.00 / M tokens** |
| Context window | **262,144 tokens** (swallows full-day transcripts whole) |
| Structured output | JSON-schema enforced during generation |

> ⚠️ **Build-time check: the exact slug.** The Fireworks catalog churns and serverless models come
> and go. Confirm `accounts/fireworks/models/kimi-k2p6` (and its price) at
> <https://fireworks.ai/models> when the account is created. **GLM-class models are interchangeable
> alternatives** — the router treats the slug as opaque config, so switching is a `config.json`
> edit, never a code change (PLAN §12 "catalog churn"). Update
> [`config.example.json`](../../config.example.json) `ai.prices_usd_per_mtok` in the same change so
> cost math stays correct.

The 262K window is why this rung, not the on-device rung (~4K), owns whole-transcript work
(transcript segmentation). But **don't dump raw** just because you can: the sensitivity gate and
retention posture (G9) still argue for sending distilled context, and output tokens are 4× the
price of input.

---

## Models are config, not code

Model slugs, endpoints, prices, and job→model routing all live in
[`config.example.json`](../../config.example.json) under `ai`, never hard-coded:

```json
"ai": {
  "routing": {
    "session_batch":    "fireworks-economy",
    "transcript_split": "fireworks-economy",
    "note_draft":       "fireworks-economy",
    "escalation":       "fireworks-escalation"
  },
  "models": {
    "fireworks-economy": {
      "provider": "fireworks",
      "model":    "accounts/fireworks/models/kimi-k2p6",
      "endpoint": "https://api.fireworks.ai/inference/v1"
    }
  },
  "prices_usd_per_mtok": {
    "accounts/fireworks/models/kimi-k2p6": { "input": 0.95, "output": 4.00 }
  },
  "budget": {
    "daily_cap_usd": { "fireworks": 2.00, "anthropic": 2.00 },
    "global_daily_cap_usd": 3.00
  }
}
```

The router resolves a `job_type` → a logical model name (`fireworks-economy`) → the concrete slug +
endpoint + price. Reprice or re-slug without touching Swift. Cost in `ai_calls.cost_usd` is computed
from `prices_usd_per_mtok`, so editing that table retro-prices future calls only (historical rows
keep their computed cost).

---

## Structured outputs — forcing the classification struct

Fireworks enforces a JSON schema **during generation** via the OpenAI-compatible `response_format`
with `type: "json_schema"`. This is how rung 4 is guaranteed to return the exact classification
struct (`{client_id, project_id, task_id?, confidence, rationale}`) rather than prose we'd have to
parse. For a **batch** we ask for an array, one element per shortlisted session.

> **Gotcha (from Fireworks docs):** include the schema in *both* the prompt text and
> `response_format` for best adherence. The provider constrains decoding to the schema, but the
> model still classifies better when the field meanings are spelled out in the prompt.

> ⚠️ **Build-time check: schema variant.** Fireworks accepts the OpenAI-standard
> `{"type":"json_schema","json_schema":{"name":…,"schema":…}}` (used below) **and** a legacy
> `{"type":"json_object","schema":{…}}` grammar form. Some middleware silently downgrades
> `json_schema` to `json_object` (drops enforcement). Verify strict enforcement is live against the
> real endpoint, and assert the returned JSON validates before trusting it (schema-invalid output
> after one retry is an escalation trigger to rung 5 — PLAN §7).

### Example request (batch of low-confidence sessions)

`session_batch` classifies several fall-through sessions in one call. Each session carries a
**distilled digest** plus the **shortlisted candidates** produced by the lexical rung (rung 2) — the
model picks among candidates, it does not free-associate over the whole Productive cache. `client_id`
/ `project_id` / `task_id` are Productive string ids (the `pd_*` PKs in
[data-model.md](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache)).

```json
{
  "model": "accounts/fireworks/models/kimi-k2p6",
  "temperature": 0.2,
  "max_tokens": 1024,
  "messages": [
    {
      "role": "system",
      "content": "You attribute work sessions to a Productive client/project/task. Choose ONLY from the candidates given for each session. If nothing fits, set client_id to \"\" and confidence low. Return JSON matching the schema."
    },
    {
      "role": "user",
      "content": "Session s-8842 digest: 'chrome — exampleorg.engagingnetworks.app donation page editor; 22m focused'. Candidates: [{client_id:\"c_017\",name:\"Example Org\"},{client_id:\"c_051\",name:\"Acme Fund\"}]; projects:[{project_id:\"p_204\",client:\"c_017\",name:\"EN donation pages\"}]; tasks:[{task_id:\"t_9931\",title:\"Q3 donation page refresh\"}].\n\nSession s-8843 digest: 'Slack #acme-website — replied to Nick re: staging selector bug; 6m'. Candidates: [{client_id:\"c_051\",name:\"Acme Fund\"}]; projects:[{project_id:\"p_310\",client:\"c_051\",name:\"Website build\"}]; tasks:[].\n\nSchema: array of {session_id, client_id, project_id, task_id?, confidence 0-1, rationale}."
    }
  ],
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "session_classification_batch",
      "schema": {
        "type": "object",
        "properties": {
          "classifications": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "session_id":  { "type": "string" },
                "client_id":   { "type": "string" },
                "project_id":  { "type": "string" },
                "task_id":     { "type": ["string", "null"] },
                "confidence":  { "type": "number", "minimum": 0, "maximum": 1 },
                "rationale":   { "type": "string" }
              },
              "required": ["session_id", "client_id", "project_id", "confidence", "rationale"],
              "additionalProperties": false
            }
          }
        },
        "required": ["classifications"],
        "additionalProperties": false
      }
    }
  }
}
```

### Example response

```json
{
  "id": "chatcmpl-9f2a1c7e",
  "object": "chat.completion",
  "created": 1753280400,
  "model": "accounts/fireworks/models/kimi-k2p6",
  "choices": [
    {
      "index": 0,
      "finish_reason": "stop",
      "message": {
        "role": "assistant",
        "content": "{\"classifications\":[{\"session_id\":\"s-8842\",\"client_id\":\"c_017\",\"project_id\":\"p_204\",\"task_id\":\"t_9931\",\"confidence\":0.91,\"rationale\":\"EN account 'exampleorg' + task title match 'donation page'\"},{\"session_id\":\"s-8843\",\"client_id\":\"c_051\",\"project_id\":\"p_310\",\"task_id\":null,\"confidence\":0.68,\"rationale\":\"Slack channel #acme-website maps to Acme Fund; no task matched\"}]}"
      }
    }
  ],
  "usage": {
    "prompt_tokens": 512,
    "completion_tokens": 96,
    "total_tokens": 608
  }
}
```

The `message.content` is a JSON string matching the schema; parse it, then write each element to the
target `sessions` row (`client_id`, `project_id`, `task_id`, `confidence`, `rationale`,
`produced_by_rung = 4`, `classified_at`). Confidence below the router threshold, a `client_id` that
contradicts a strong lexical prior, or transcript math that doesn't reconcile → escalate to rung 5
(Claude) with this attempt in the prompt (PLAN §7 rung 5).

---

## Reading `usage` → the `ai_calls` ledger (G5)

Every Fireworks call writes exactly one row to
[`ai_calls`](../architecture/data-model.md#ai-ledger--nudges-phase-6) from the single metered call
site. Map the response's `usage` block straight onto the ledger columns:

| `usage` field | `ai_calls` column |
|---|---|
| `prompt_tokens` | `input_tokens` |
| `completion_tokens` | `output_tokens` |
| — (computed) | `cost_usd` |
| — (measured) | `latency_ms` |
| — | `provider = 'fireworks'`, `model`, `job_type`, `outcome`, `request_ref` |

`job_type` is one of `'session_batch'`, `'transcript_split'`, `'note_draft'`, `'calibration'`
(exact enum in [data-model.md](../architecture/data-model.md#ai-ledger--nudges-phase-6)).
`request_ref` records what was classified (e.g. the session ids or a meeting id) for auditability.

Cost is computed from the config price table:

```swift
// input/output prices come from config.ai.prices_usd_per_mtok[model]
func costUSD(inputTokens: Int, outputTokens: Int, price: ModelPrice) -> Double {
    (Double(inputTokens)  / 1_000_000 * price.input) +
    (Double(outputTokens) / 1_000_000 * price.output)
}

// after a successful Fireworks call:
let cost = costUSD(inputTokens: usage.promptTokens,
                   outputTokens: usage.completionTokens,
                   price: price)   // e.g. 512/1e6*0.95 + 96/1e6*4.00 = $0.00087
try ledger.record(AiCall(
    occurredAt:  clock.now,
    jobType:     .sessionBatch,
    provider:    "fireworks",
    model:       "accounts/fireworks/models/kimi-k2p6",
    inputTokens:  usage.promptTokens,
    outputTokens: usage.completionTokens,
    costUsd:      cost,
    latencyMs:    elapsedMs,
    outcome:     .ok,
    requestRef:  "sessions:[s-8842,s-8843]"))
```

This is what powers the dashboard's AI-overhead panel (month-to-date spend, cost by job type,
escalation rate) and the CSV export for internal accounting (PLAN §7 "AI usage ledger").

> **Reconcile against the provider dashboard.** Phase 6 acceptance requires the ledger's summed
> `cost_usd` to reconcile against the Fireworks billing dashboard. If Fireworks reports token counts
> in a `usage` shape that differs (e.g. cached-prompt tokens), record what it returns and true it up.

---

## Batching low-confidence sessions

Rung 4 is a **batch** rung, not a per-session rung. The router accumulates fall-through sessions
(those rungs 1–3 couldn't settle) and classifies them in one call:

- **Fewer requests, cheaper.** One prompt's system message + shared candidate context amortizes over
  N sessions; per-session HTTP overhead disappears.
- **Cap the batch.** Bound each request well under the 262K window (a digest is ~50–150 tokens; keep
  batches to a few dozen sessions so a single schema-invalid response doesn't sink a whole day).
- **Idempotent.** Re-running a batch upserts `sessions` classifications; already-settled sessions are
  filtered out before the call (never re-pay for rung-1/2 results — G4).
- **Transcript segmentation is separate** (`job_type='transcript_split'`): one call per meeting,
  returning time-bounded per-client segments tied to `transcript_utterances` offsets (PLAN §8
  "Meeting splitting"). It is the one place a large slice of the window is legitimately used.

---

## Budget caps → local-only (G5)

Per-provider daily caps and a global cap live in `config.ai.budget`. The budget check runs
**before** dispatch:

1. Sum today's `ai_calls.cost_usd` for `provider='fireworks'` (and across all providers for the
   global cap).
2. If this call's *estimated* cost would exceed either cap, **refuse it**: write an `ai_calls` row
   with `outcome='refused_budget'` (zero tokens), skip the network call, and flip the app to
   **local-only** mode with the attention-needed menu bar badge.
3. Local-only means the ladder stops at rung 2 (rules + lexical); those sessions stay
   `pending`/unclassified and surface in the recap for manual attribution rather than failing
   silently.

Never send a Fireworks call that isn't both gated (G2) and under-cap (G5). There is no bypass path.

---

## Gotchas

- **Slug drift** — the #1 failure mode. A 404 / "model not found" means the catalog moved; the router
  should surface it (not crash) and the fix is a `config.json` slug edit. Keep GLM-class fallbacks in
  mind (PLAN §12).
- **`json_schema` silently downgraded** — some proxies coerce it to `json_object` (no enforcement).
  Always validate the parsed JSON against the expected struct; treat a validation failure as a retry,
  then an escalation.
- **429 / rate limits** — Fireworks returns HTTP 429 under load. Back off and retry per the general
  ingest retry policy; a persistent 429 that blocks a batch is not an escalation to Claude, it's a
  transient error (`outcome='error'` then retry).
- **Output tokens cost 4×** — keep `max_tokens` tight and prefer terse `rationale` strings; the note
  itself is a separate `note_draft` job.
- **Never log the key** — the outbound-payload log (G2 enforcement) strips the `Authorization`
  header; the logger redacts anything token-shaped (G6).
- **Temperature low** — classification wants determinism; use a low temperature (~0.2) so the same
  session batch classifies stably across re-runs.
