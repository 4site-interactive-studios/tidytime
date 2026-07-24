# Apple Foundation Models — on-device rung (ladder rung 3)

The on-device classifier: Apple's ~3B-parameter model via the Foundation Models framework, driven
with guided generation (`@Generable`) to force the classification struct. Free, private, and
on-device — but bounded by a small context window, so it consumes distilled digests, never raw dumps.

**Related:** [docs index](../README.md) · [PLAN.md §7](../../PLAN.md) ·
[fireworks-ai.md](fireworks-ai.md) ·
[classification-ladder.md](../architecture/classification-ladder.md) ·
[ai-provider-router.md](../conventions/ai-provider-router.md) ·
[guardrails.md](../guardrails.md)

---

**Status:** active · **Base URL:** n/a (on-device framework, no network) ·
**Auth:** none (no key; runs locally, exempt from G6 secrets handling) ·
**Source:** <https://developer.apple.com/documentation/foundationmodels>,
<https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel>,
<https://developer.apple.com/videos/play/wwdc2025/286/> (Meet the Foundation Models framework),
Apple TN3193, <https://machinelearning.apple.com/research/apple-foundation-models-2025-updates> ·
**Last verified:** 2026-07-23

---

## What this rung is

Rung 3 sits between local lexical matching (rung 2) and the economy cloud tier (rung 4). It's the
last **free, fully-private** stop before any bytes could leave the device. Because it's on-device it
is **exempt from transmission concerns** — content that reaches this rung never crosses the network —
but note generation here still honors the generic-fallback rule (see [Sensitivity](#sensitivity--g2)).

Lives in **`TidyAI`** as `AppleOnDeviceProvider` behind the `AIProvider` protocol
([module-map](../architecture/module-map.md#protocol-seams-the-extension-points)). If the model is
unavailable, the ladder simply **skips this rung** and falls through to rung 4 — no error, no prompt.

| | |
|---|---|
| Framework | `FoundationModels` (import) |
| Model | on-device system model, **~3B parameters** (Apple Intelligence) |
| Requires | **macOS 26+** and **Apple Intelligence enabled** in System Settings |
| Deployment | app target is macOS 14; this rung is **runtime-gated** — never a hard link requirement |
| Cost | $0 (on-device); still ledgered for the "share resolved free" metric |

---

## Availability check + graceful skip

Always check `SystemLanguageModel.availability` before creating a session. The framework only runs on
Apple-Intelligence-eligible, enabled devices in supported regions; on everything else this rung is a
no-op and the router advances to Fireworks (rung 4).

```swift
import FoundationModels

enum OnDeviceAvailability {
    case ready
    case skip(reason: String)   // router falls through to rung 4
}

func onDeviceAvailability() -> OnDeviceAvailability {
    // Guarded at runtime; the symbol only exists on macOS 26+.
    guard #available(macOS 26, *) else { return .skip(reason: "macOS < 26") }

    switch SystemLanguageModel.default.availability {
    case .available:
        return .ready
    case .unavailable(let reason):
        // reason ∈ .deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady
        return .skip(reason: "\(reason)")
    @unknown default:
        return .skip(reason: "unknown")
    }
}
```

> ⚠️ **Build-time check: availability API surface.** The `SystemLanguageModel.default.availability`
> enum and its `unavailable` reason cases are current per Apple docs (2025), but the exact case names
> can shift between betas. Verify `.available` / `.unavailable(_)` and the reason enum against the SDK
> you build with; treat *any* non-`.available` state as "skip to rung 4."

**Design rule:** a skipped rung 3 is normal, not a failure. PLAN §7: "If Apple Intelligence is off,
the ladder skips this rung," costing pennies more at rung 4. Don't nag the user to enable it; surface
it once in the `doctor` view (permission/capability status) and move on.

---

## Guided generation — forcing the classification struct

The whole reason to use this rung (vs. free-text) is **guided generation**: a `@Generable` struct
constrains decoding so the model must return exactly `{client_id, project_id, task_id?, confidence,
rationale}` — the same shape rung 4 produces, so downstream code is rung-agnostic. Fields map to the
`sessions` columns in
[data-model.md](../architecture/data-model.md#capture-tables-phase-1) (`client_id`, `project_id`,
`task_id`, `confidence`, `rationale`, with `produced_by_rung = 3`).

```swift
import FoundationModels

@Generable
struct SessionClassification {
    @Guide(description: "Productive company (client) id, chosen ONLY from the candidate list; empty string if none fit")
    let clientId: String

    @Guide(description: "Productive project id under that client, from the candidates")
    let projectId: String

    @Guide(description: "Productive task id if one clearly matches, otherwise omit")
    let taskId: String?

    @Guide(description: "Confidence from 0.0 (guess) to 1.0 (certain)")
    let confidence: Double

    @Guide(description: "One short sentence naming the signal that decided it, e.g. \"EN account 'exampleorg'\"")
    let rationale: String
}

@available(macOS 26, *)
func classifyOnDevice(digest: String, candidates: String) async throws -> SessionClassification {
    let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: """
        Attribute one work session to a Productive client/project/task.
        Choose only from the candidates provided. If nothing fits, set clientId to "" and confidence low.
        """
    )
    let prompt = """
    Session digest: \(digest)
    Candidates: \(candidates)
    """
    let response = try await session.respond(to: prompt, generating: SessionClassification.self)
    return response.content   // a fully-populated SessionClassification, schema-guaranteed
}
```

> ⚠️ **Build-time check: `@Generable` / `@Guide` API.** The macro names and `session.respond(to:
> generating:)` signature are current per WWDC25 / Apple docs, but `@Guide` constraint helpers (e.g.
> numeric ranges, enum guides) and the `respond` overloads evolve. Verify against the FoundationModels
> SDK you build with. If a `@Guide` range helper for `Double` isn't available, keep the
> description-only guide above and clamp `confidence` after decoding.

Unlike rung 4, there is **no JSON to parse** — `response.content` is already the typed struct. There
is also **no key and no `usage`/cost** to send; the only "reading response" work is writing the ledger
row (below).

---

## The ~4,096-token context window is the hard design constraint

> ⚠️ **Build-time check: the exact figure.** PLAN §7 and community docs (TN3193) put the on-device
> window at **~4,096 tokens**. Apple's official docs don't publish a single canonical number and it
> may differ by OS version. Confirm the real limit on the build machine (a quick over-length probe)
> and treat 4,096 as the conservative design budget until measured.

This is small — roughly 1/64th of Fireworks' 262K. It dictates the entire prompt strategy for this
rung:

- **Send a distilled session digest, never raw dumps.** No page-text `page_snapshots`, no full window
  titles, no transcript. A digest is the normalized dominant signal + a few tokens of context, e.g.
  `"chrome — exampleorg.engagingnetworks.app donation editor; 22m focused"`.
- **Only the shortlisted candidates.** Pass the top few client/project/task candidates the lexical
  rung (rung 2) already produced — not the whole Productive cache. The model *chooses among
  candidates*; it does not search.
- **One session per call** (not batched). Batching is a rung-4 optimization; here the window forbids
  it. If you must classify many, loop — each call is free.
- **No few-shot bloat.** At most one or two recent `decisions` as few-shot examples (PLAN §7 learning
  loop); drop them first if the window is tight.

If a digest + candidates would exceed the budget, **truncate the digest**, not the candidate list —
losing a candidate loses the right answer. Whole-transcript work belongs to rung 4
([fireworks-ai.md](fireworks-ai.md#batching-low-confidence-sessions)), which has the window for it.

This is exactly the summarization/extraction/classification shape Apple says the on-device model is
built for (PLAN §7) — right-sized, not underpowered, as long as inputs are digests.

---

## Sensitivity & G2

On-device calls **stay on device**, so they are exempt from the transmission gate that guards cloud
payloads — content that trips the sensitivity gate can still be *classified locally* here without
violating [G2](../guardrails.md#g2--the-sensitivity-gate-fails-closed). **But note generation still
honors the generic-fallback rule:** if content is sensitive, the suggestion falls back to a generic
task and a bland note regardless of which rung produced the attribution. In practice:

- **Attribution** (client/project/task) via on-device is allowed for sensitive sessions.
- **Note drafting** for sensitive sessions still yields the bland generic note — do not have the
  on-device model write a descriptive note about flagged/personnel/comp/legal content.
- Set `sessions.is_sensitive = 1` so downstream (suggestion engine, any later cloud step) never
  re-exposes it. A sensitive session must **never** subsequently be handed to rung 4.

---

## Ledger (G5)

On-device calls are metered too, so the dashboard's "share resolved free on-device" metric is real.
Write one [`ai_calls`](../architecture/data-model.md#ai-ledger--nudges-phase-6) row per call:

| Column | Value |
|---|---|
| `provider` | `'apple'` |
| `model` | on-device model identifier (⚠️ **Build-time check** — no formal public slug; use a stable label like `'apple-on-device'`) |
| `job_type` | `'on_device_classify'` |
| `input_tokens` / `output_tokens` | best-effort; the framework may not expose token counts — record `0` or an estimate if unavailable (⚠️ Build-time check) |
| `cost_usd` | **`0`** (on-device is free) |
| `latency_ms` | measured |
| `outcome` | `'ok'` \| `'error'` |
| `request_ref` | the session id classified |

No budget cap applies (cost is zero), but the row still counts toward the "on-device share" and
escalation-rate analytics. There is **no `refused_budget` path** for this rung.

---

## Routing: when rung 3 runs, and when it escalates

- **Runs** when: rungs 1–2 fell through (no confident rule/lexical match) **and**
  `onDeviceAvailability() == .ready` **and** `config.ai.on_device.enabled == true`.
- **Settles** the session when `confidence` clears the router threshold and doesn't contradict a
  strong lexical prior → write `sessions` with `produced_by_rung = 3`.
- **Falls through to rung 4** (Fireworks) when: model unavailable, confidence below threshold, or the
  result contradicts a strong prior. On-device failure is *not* an escalation to Claude — it's a
  normal step down the ladder to the economy cloud tier.

Every suggestion records its rung (`produced_by_rung`) and `rationale`, so on-device attributions are
as inspectable as any other (guardrail
[G4](../guardrails.md#g4--local-first-then-cheap-then-smart)).

---

## Gotchas

- **Availability is per-device and per-region**, not just per-OS. Eligible hardware with Apple
  Intelligence *disabled* is `.unavailable(.appleIntelligenceNotEnabled)` → skip, don't error.
- **First-use model download / warm-up.** `.unavailable(.modelNotReady)` can occur while assets load;
  treat as transient skip and retry the session later, not as a hard failure.
- **Guided generation is not infallible.** The struct is enforced, but a wrong-but-well-typed answer
  is still possible; the confidence threshold + contradiction-with-lexical-prior checks are what catch
  it, exactly as for rung 4.
- **Don't hard-link the framework.** Weak-link / runtime-gate so the app still launches and runs the
  cloud ladder on macOS 14–25 where FoundationModels is absent (module-map: rung 3 degrades
  gracefully).
- **Keep prompts terse.** Every token spent on instructions is a token not available for candidates;
  move standing guidance into `instructions` and the `@Guide` descriptions, not the per-call prompt.
- **No secrets, nothing to redact** — but the same digest-only discipline (no page text, no raw
  transcript) keeps the retention/privacy posture (G9) consistent across rungs.
