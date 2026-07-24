# TidyAI

The provider router and the **only** place cloud AI calls happen: on-device, Fireworks, and
Anthropic rungs, each gated, metered into `ai_calls`, and bounded by budget caps.

Related: [docs index](../../../../docs/README.md) ·
[classification-ladder](../../../../docs/architecture/classification-ladder.md) ·
[ai-provider-router](../../../../docs/conventions/ai-provider-router.md) ·
[guardrails](../../../../docs/guardrails.md) ·
[TidyUnderstand](../TidyUnderstand/README.md)

## Responsibility

Routes rungs **3–5** (on-device → economy cloud → Claude), accepts only pre-gated payloads, writes
a ledger row for every call, and refuses over-cap requests before dispatch.

## Phase

Builds in **Phase 6** (intelligence).

## Dependencies

- Internal: **TidyCore**, **TidyStore**. Independent of TidyCapture / TidyIngest / TidyUnderstand.

## Key types & files

| Type / file | Purpose |
|---|---|
| `AIRouter` (`AIRouting`) | Single metered call site; dispatches to a provider by rung / config. |
| `AppleOnDeviceProvider` | Rung 3 — Apple Foundation Models, `@Generable` guided generation (macOS 26 + Apple Intelligence). |
| `FireworksProvider` | Rung 4 — OpenAI-compatible economy tier; model name is config, not code. |
| `AnthropicProvider` | Rung 5 — Claude escalation + calibration sample. |
| `UsageLedger` | Writes `ai_calls` (provider / model / tokens / cost / latency / outcome). |
| `BudgetCap` | Per-provider daily + global caps, checked **before** dispatch → local-only on trip (G5). |

## Tables

- **Writes:** `ai_calls`.
- **Reads:** `ai_calls` (day-to-date spend for cap evaluation).

## Protocol seams

**Implements** `AIProvider` (the three providers) and exposes the router seam declared in TidyCore
that TidyUnderstand / TidySuggest consume. **Consumes** `SecretStore` (Fireworks / Anthropic keys —
G6) and requires `GatedPayload` input (G2). Guardrails: **G2**, **G4**, **G5**, **G6**.
