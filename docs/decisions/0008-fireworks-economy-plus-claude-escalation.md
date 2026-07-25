# 0008 — Fireworks economy tier + Claude escalation

> **Superseded by [0013](0013-all-cloud-inference-through-fireworks.md)** (2026-07-25):
> escalation now routes through Fireworks too. The record below is left as written — it says what
> was true when it was accepted.

Fireworks AI (open-weight models, OpenAI-compatible) is the cloud workhorse; Claude is invoked only
on escalation; every cloud call is metered into a local ledger and bounded by budget caps.

Related: [README.md](README.md) · [../guardrails.md](../guardrails.md) ·
[../reference/fireworks-ai.md](../reference/fireworks-ai.md) ·
[0003](0003-local-first-classification-ladder.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

Rungs 4–5 of the ladder ([0003](0003-local-first-classification-ladder.md)) need cloud reasoning
for what local rungs can't settle: low-confidence session batches, transcript segmentation, note
drafting. Sending all of it to Claude would be needlessly expensive. Open-weight economy models are
an order of magnitude cheaper and, on this extraction/classification work, good enough for the
first pass — with Claude held in reserve to adjudicate the hard cases (PLAN §2, §7).

## Decision

- **Rung 4 — Fireworks AI** as the economy workhorse: OpenAI-compatible endpoint
  `https://api.fireworks.ai/inference/v1` with structured-output support, so one client library
  covers every model. **Model names are config strings, not code** — the catalog churns (PLAN §7,
  §12). Per PLAN §7, Kimi K2.6 is confirmed today at **$0.95/M input, $4.00/M output, 262K context**
  (⚠️ Build-time check: confirm live pricing/models at fireworks.ai when the account is created).
- **Rung 5 — Claude escalation** only when rung 4 earns it: schema-invalid output after one retry,
  self-reported confidence below threshold, transcript segments that don't sum to the recording
  duration, or a result contradicting a strong lexical prior — plus a **decaying calibration
  sample**. Escalations carry the cheap model's attempt so Claude adjudicates, not restarts.
- **Metering + caps:** every rung 3–5 call writes an `ai_calls` row (provider, model, tokens,
  `cost_usd` from the config price table, latency, outcome); per-provider daily caps + a global cap;
  tripping any cap drops the app to local-only with a menu-bar badge. Guardrail
  **[G5](../guardrails.md#g5--every-cloud-ai-call-is-metered-and-capped)**.

## Consequences

- Cloud spend is attributable overhead: the dashboard shows month-to-date cost, cost by job type,
  escalation rate ("is the cheap tier earning its keep"), and on-device share, with CSV export.
- The router is the **single metered call site** in `TidyAI`; there is no path to a provider that
  skips the ledger, and the budget check runs **before** dispatch (over-cap → refused, logged, not
  sent).
- All cloud calls run **after** the sensitivity gate ([0004](0004-sensitivity-gate-fail-closed.md));
  a third provider (Fireworks) sees more distilled content than a Claude-only design — the accepted
  trade for volume, with the gate applied identically to every provider.
- Catalog/pricing churn is contained: routing and the price table are config, tuned from the
  calibration sample against the user's real data.

## Alternatives considered

- **Claude-only for all cloud work.** Rejected: far higher cost for first-pass extraction the
  economy tier handles; Claude is better spent adjudicating.
- **Economy-only, no Claude.** Rejected: open-weight quality varies by task and catalog churns;
  escalation + calibration catch individual failures and measure trust (PLAN §12).
- **Model names hard-coded.** Rejected: the Fireworks lineup changes; names must be config so a
  swap is a settings edit, not a code change.
