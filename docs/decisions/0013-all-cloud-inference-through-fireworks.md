# 0013 — All cloud inference through Fireworks; Anthropic is an optional direct path

**Status:** Accepted · **Date:** 2026-07-25 · **Supersedes:** [0008](0008-fireworks-economy-plus-claude-escalation.md)

## Context

[ADR 0008](0008-fireworks-economy-plus-claude-escalation.md) split the cloud rungs by **vendor**:
rung 4 = economy open-weight models on Fireworks, rung 5 = Anthropic's Claude for escalation. That
required two provider accounts, two API keys, two billing relationships, and two price tables for a
single-user tool.

The product owner asked that escalation also go through Fireworks — one vendor, one key, one ledger.

An important constraint shapes the result: **Claude (and Fable) are proprietary and are not served on
Fireworks.** Third-party inference platforms host open-weight models only. "Escalate via Fireworks"
therefore cannot mean "escalate to Claude"; it means escalating to a *stronger open-weight* model.

## Decision

1. **All cloud inference — economy *and* escalation — routes through Fireworks by default.** This is
   a `config.json` change only (`ai.routing.escalation` → a Fireworks model); the router already
   resolves job → model → provider from config, so no code changes.
2. **The escalation rung is a capability step, not a price step.** It runs a stronger/different
   open-weight adjudicator, carrying the cheap model's attempt in the prompt. ⚠️ **Build-time check:**
   pick the actual best available adjudicator when the account is created; the committed slug is a
   placeholder.
3. **The Anthropic path remains implemented but off by default.** `AnthropicProvider` and the
   `anthropic-claude` model entry stay; enabling them is a one-line routing change plus a key. This
   is the only way to get Claude/Fable-grade adjudication if it is ever required.

## Consequences

- **Simpler operations:** one key in the Keychain, one budget cap that matters, one provider
  dashboard to reconcile the `ai_calls` ledger against.
- **Rung 4→5 is no longer a cost escalation.** Round-2 review (R3-4) noted the placeholder escalation
  model is *cheaper per token* than the economy model, inverting the ladder's original economics. The
  ladder's local-first claim (G4) is unaffected — it is about **staying local**, and rungs 1–3 still
  resolve most work for free. But rungs 4/5 must now be described as a **capability** split, and the
  ladder doc says so.
- **A metric had to be repaired.** The dashboard classified the economy tier by *provider name*, so
  once both tiers were "fireworks" escalations landed inside their own denominator and corrupted
  `escalationRate` (round-2 finding R3-1). Tier is now derived from the **job**, not the vendor. The
  general lesson: *routing changes can silently break metrics that key on the routing dimension.*
- **Calibration weakens slightly.** 0008's calibration sample compared the cheap tier against a
  frontier model. Comparing two open-weight models is a weaker signal; if calibration ever needs to
  be authoritative, enable the Anthropic path for the sample only.

## Alternatives considered

- **Keep 0008 (Claude escalation).** Best adjudication quality; rejected as the default because it
  requires a second vendor/key/bill for a single-user tool. Retained as an opt-in path.
- **Drop the escalation rung entirely.** Simplest, but removes the safety net for schema-invalid or
  low-confidence output, which is exactly where attribution errors would reach the user.
- **A second vendor for escalation only (e.g. Together/Groq).** Same two-vendor overhead as 0008
  without Claude's quality.
