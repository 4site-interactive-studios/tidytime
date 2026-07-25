# AI provider router (TidyAI code contract)

The code-level contract for `TidyAI`: the `AIProvider` protocol, the config-driven routing
table, and the **single metered call site** every cloud call funnels through — sensitivity gate
→ budget check → dispatch → ledger. Complements the policy in
[classification-ladder.md](../architecture/classification-ladder.md); this doc is the *how it's
built*, that doc is the *when each rung fires*.

**Related:** [doc index](../README.md) · [PLAN §7](../../PLAN.md) ·
[classification ladder](../architecture/classification-ladder.md) · [data model](../architecture/data-model.md) ·
[guardrails](../guardrails.md) · [module map](../architecture/module-map.md) ·
[error handling & logging](error-handling-logging.md)

---

## Where this lives & what it guarantees

`TidyAI` is the **only** target where cloud calls happen ([module map](../architecture/module-map.md)).
It owns the router, the three `AIProvider` implementations, and the usage ledger. Every path
through it upholds:

- **G4** — it is invoked only on ladder fall-through; rungs 1–2 never reach it.
- **G2** — it accepts only a `GatedPayload` (produced solely by the `SensitivityGate` in
  `TidyUnderstand`); sensitive content is structurally unable to enter a request.
- **G5** — the budget check runs **before** dispatch and **every** call writes an `ai_calls` row.
- **G6** — provider keys come from `SecretStore` (Keychain) at the point of the HTTP call and are
  never logged (auth headers stripped in the outbound-payload log —
  [error-handling-logging.md §7](error-handling-logging.md)).

## The `AIProvider` protocol

One capability: take a request, return structured output plus token usage. Three conformers,
selected by config, never by `if provider == …` in call sites.

```swift
public protocol AIProvider: Sendable {
    /// 'apple' | 'fireworks' | 'anthropic' — matches ai_calls.provider.
    var providerId: String { get }

    /// One classify/generate call. Throws AIProviderError; does NOT retry, meter, or gate —
    /// those are the router's job (single metered call site, below).
    func complete(_ request: AIRequest) async throws -> AIResponse
}

public struct AIRequest: Sendable {
    public let job: AIJob            // maps to ai_calls.job_type
    public let model: String        // resolved config slug — NEVER a literal (see routing)
    public let endpoint: URL        // from config.ai.models[key].endpoint
    public let payload: GatedPayload// gate-produced; the only content type accepted (G2)
    public let schema: ResponseSchema // structured-output / @Generable contract
    public let requestRef: String   // session ids / meeting id → ai_calls.request_ref
}

public struct AIResponse: Sendable {
    public let json: Data           // structured output, validated against request.schema
    public let inputTokens: Int
    public let outputTokens: Int
    public let confidence: Double?  // model self-report where available (drives 3→4 / 4→5)
    public let modelReported: String// model the provider says it served
}

public enum AIJob: String, Sendable {   // rawValue == ai_calls.job_type
    case sessionBatch = "session_batch",  transcriptSplit = "transcript_split"
    case noteDraft = "note_draft",        calibration = "calibration"
    case escalation = "escalation",       onDeviceClassify = "on_device_classify"
}
```

v1 conformers (module map §Protocol seams): `AppleOnDeviceProvider` (rung 3, on-device, free),
`FireworksProvider` (rung 4, OpenAI-compatible), `AnthropicProvider` (rung 5). Adding a model is
**config**, not a new type ([fireworks-ai](../reference/fireworks-ai.md) catalog churns).

Typed errors ([error-handling-logging.md §2](error-handling-logging.md)):

```swift
public enum AIProviderError: Error, Sendable {
    case schemaInvalid(raw: String)        // structured output didn't match request.schema
    case http(status: Int)                 // includes 429; router maps to retry/backoff
    case transport(underlying: String)     // redacted; never leaks a key
    case unavailable                       // Apple Intelligence off → rung 3 skipped
}
```

## Model names are strictly config

Providers and model slugs are resolved from `config.ai.routing` (job → model *key*) and
`config.ai.models` (key → `{provider, model, endpoint}`). **No model string is ever a literal in
code.** The canonical config shape lives in `config.example.json` and is documented in
[classification-ladder.md §Config](../architecture/classification-ladder.md#config-keys):

```json
"ai": {
  "routing": { "session_batch": "fireworks-economy", "transcript_split": "fireworks-economy",
               "note_draft": "fireworks-economy", "escalation": "fireworks-escalation" },
  "models":  { "fireworks-economy": { "provider": "fireworks",
                 "model": "accounts/fireworks/models/kimi-k2p6",
                 "endpoint": "https://api.fireworks.ai/inference/v1" },
               "anthropic-claude": { "provider": "anthropic", "model": "claude-opus-4-8",
                 "endpoint": "https://api.anthropic.com/v1" } }
}
```

Resolution binds-or-throws (no force-unwrap, per [swift-style §5](swift-style.md)):

```swift
struct ModelRouting: Sendable {
    let routing: [String: String]          // config.ai.routing
    let models:  [String: ModelConfig]     // config.ai.models  (provider, model, endpoint)

    func resolve(_ job: AIJob) throws -> ModelConfig {
        guard let key = routing[job.rawValue], let cfg = models[key]
        else { throw AIRouterError.unroutable(job) }
        return cfg
    }
}
```

⚠️ **Build-time check:** confirm exact Fireworks model slugs at the provider (catalog churns) and
set live prices in `config.ai.prices_usd_per_mtok` (Claude prices are `null` until entered).

## The single metered call site

Every cloud (and on-device) call goes through **one** funnel — the `AIRouter` actor's `run`.
There is no other path to a provider. This is where G2/G5 are enforced and where the `ai_calls`
row is written.

**Order of operations (never reordered):**

1. **Sensitivity gate.** The request already carries a `GatedPayload`; the router additionally
   asserts the gate verdict is `.clear`. A `.sensitive` request is **refused, not sent** →
   ledger `outcome = 'refused_sensitive'`, `cost_usd = 0`. (Belt-and-suspenders on top of the
   type-level guarantee — [understand-layer §3](../architecture/understand-layer.md).)
2. **Budget check — BEFORE dispatch** (cloud rungs only; rung 3/`apple` is free and skips it but
   is still ledgered). Over-cap → **refused, not sent** → ledger `outcome = 'refused_budget'`,
   `cost_usd = 0`; the app drops to local-only with a menu-bar badge
   ([classification-ladder §Budget](../architecture/classification-ladder.md#budget-cap--local-only-g5)).
3. **Provider call** with retry-once (§retry).
4. **Write the `ai_calls` row** — provider, model, tokens, `cost_usd` from the config price
   table, latency, `request_ref`, outcome. No un-ledgered call exists (G5).
5. **Return the outcome** to the ladder, which decides settle-vs-escalate.

```swift
public actor AIRouter: AIRouting {
    private let providers: [String: any AIProvider]   // keyed by providerId
    private let routing: ModelRouting
    private let ledger: AiCallsDAO                     // writes ai_calls
    private let prices: PriceTable                     // config.ai.prices_usd_per_mtok
    private let caps: BudgetCaps                       // config.ai.budget
    private let payloadLog: OutboundPayloadLog         // DEBUG/opt-in; strips auth (G2/G6)
    private let clock: any Clock

    public func run(_ req: AIRequest, gate: GateResult) async throws -> AIResponse {
        let started = clock.now

        // 1) Sensitivity gate — refuse, don't send.
        guard case .clear = gate else {
            ledger.insert(row(req, outcome: "refused_sensitive", cost: 0, at: started))
            throw AIRouterError.refusedSensitive
        }

        let cfg = try routing.resolve(req.job)                 // config-driven; no literals
        guard let provider = providers[cfg.provider] else { throw AIRouterError.unroutable(req.job) }
        let isCloud = provider.providerId != "apple"

        // 2) Budget check BEFORE dispatch (cloud only).
        if isCloud {
            let est = prices.estimate(model: cfg.model, payload: req.payload)
            if Budget.gate(provider: provider.providerId, estCostUSD: est,
                           ledger: ledger, caps: caps, day: clock.today) == .refuse {
                ledger.insert(row(req, outcome: "refused_budget", cost: 0, at: started))
                throw AIRouterError.refusedBudget                // → local-only + menu-bar badge
            }
            payloadLog.record(provider: provider.providerId, model: cfg.model,
                              job: req.job.rawValue, requestRef: req.requestRef,
                              body: req.payload.body, headers: req.safeHeaders)   // auth stripped
        }

        // 3) Provider call with retry-once.
        do {
            let (resp, retried) = try await callWithOneRetry(provider, req)
            // 4) Ledger the successful call.
            let cost = isCloud ? prices.cost(model: cfg.model,
                                             input: resp.inputTokens, output: resp.outputTokens) : 0
            ledger.insert(row(req, resp: resp, outcome: retried ? "retried" : "ok",
                              cost: cost, latencyMs: clock.msSince(started), at: started))
            return resp                                          // 5) ladder decides settle/escalate
        } catch let e as AIProviderError {
            ledger.insert(row(req, outcome: "error", cost: 0,
                              latencyMs: clock.msSince(started), error: e, at: started))
            throw e
        }
    }
}
```

The router **does not** decide fall-through — it returns `AIResponse` (and ledgers). The ladder
in `TidyUnderstand` reads `confidence`, validates the structured output, checks segment sums /
strong-prior conflicts, and calls `run` again for the next rung when needed
([classification-ladder §fall-through](../architecture/classification-ladder.md#exact-fall-through-conditions)).

## Retry-once-then-escalate

A **single** structured-output/`@Generable` violation (`AIProviderError.schemaInvalid`) triggers
one re-ask at the same rung; a second failure is a **fall-through, not an error swallow**. `429`
gets one honor-`Retry-After` retry, then surfaces as `.http(429)`.

```swift
private func callWithOneRetry(_ p: any AIProvider, _ req: AIRequest)
        async throws -> (AIResponse, retried: Bool) {
    do { return (try await p.complete(req), false) }
    catch AIProviderError.schemaInvalid {
        return (try await p.complete(req), true)   // exactly one re-ask; 2nd throw propagates
    }
}
```

When the ladder decides a rung-4 result must go to Claude (schema-invalid ×2, `conf <
economy_min`, segment sums off, strong-prior conflict), it **updates the rung-4 `ai_calls` row's
`outcome` to `'escalated'`** and issues a fresh `run` with `job = .escalation` — whose escalation
prompt **carries the rung-4 attempt** so Claude adjudicates rather than restarts
([classification-ladder rung 5](../architecture/classification-ladder.md)).

## Outcome semantics (maps to `ai_calls.outcome`)

| `outcome` | Meaning | Dispatched? | `cost_usd` |
|---|---|---|---|
| `ok` | Succeeded first try | yes | metered (0 for `apple`) |
| `retried` | Succeeded after the one re-ask | yes | metered |
| `escalated` | Rung-4 result handed to rung-5; row patched by the ladder | yes | metered |
| `error` | Failed after retry (transport / `http` / schema-invalid ×2 with no higher rung) | yes | 0 |
| `refused_budget` | Over cap — never sent (G5) | **no** | 0 |
| `refused_sensitive` | Gate verdict `.sensitive` — never sent (G2) | **no** | 0 |

Every `ai_calls` row also carries `occurred_at`, `job_type`, `provider`, `model`,
`input_tokens`, `output_tokens`, `latency_ms`, and `request_ref`
([data-model.md](../architecture/data-model.md) `ai_calls`). Rung 3 is ledgered with
`provider = 'apple'`, `job_type = 'on_device_classify'`, `cost_usd = 0` so the on-device-share
metric counts it.

## Calibration sampling

After a rung-4 result would be **accepted**, a decaying fraction gets a Claude second opinion via
the **same** `run` funnel with `job = .calibration` — so it is gated, budget-checked, and
ledgered like any other cloud call: `provider = 'anthropic'`, `job_type = 'calibration'`, with a
normal `outcome` (`ok`/`retried`/`error`). Rates come from
`config.ai.calibration` ([classification-ladder §Calibration](../architecture/classification-ladder.md#calibration-sample)).

```swift
func shouldCalibrate(day: String, cal: CalibrationConfig, rng: inout some RandomNumberGenerator,
                     firstActivity: String) -> Bool {
    let elapsedDays = daysBetween(firstActivity, day)
    let rate = elapsedDays <= cal.decayAfterDays
        ? cal.initialSampleRate
        : max(cal.floorSampleRate, cal.initialSampleRate * decayFactor(elapsedDays, cal))
    return Double.random(in: 0..<1, using: &rng) < rate
}
```

The economy result stays the classification unless Claude disagrees materially, in which case
Claude wins and the disagreement feeds routing tuning (the dashboard's "is the cheap tier earning
its keep" read-out).

## Invariants checklist (Phase 6)

- [ ] No call reaches a provider except through `AIRouter.run` — the single metered site.
- [ ] Budget is checked **before** dispatch; over-cap requests are `refused_budget`, never sent.
- [ ] A `.sensitive` gate verdict yields `refused_sensitive`, never sent; the phrase appears in
      no `OutboundPayloadLog` record (G2, shared with
      [understand-layer](../architecture/understand-layer.md)).
- [ ] Every dispatched call writes exactly one `ai_calls` row whose `cost_usd` reconciles against
      the provider dashboard (on-device `= 0`).
- [ ] Model slugs come only from `config.ai.models`; grep finds no hardcoded model string in
      `Sources/TidyAI`.
- [ ] Schema-invalid retries exactly once, then escalates; a clean high-confidence rung-4 result
      does **not** escalate.
