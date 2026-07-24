# Phase 6 retrospective — Intelligence

**Date:** 2026-07-24 · **Status:** ✅ logic complete, tests green (117 total, +19) · **Commit:** `feat(phase-6)`

## What shipped (code-complete + unit-tested)

| Area | Type(s) | Tested by |
|---|---|---|
| Schema | `v1-ai` (ai_calls, nudges) + DAOs (spend, dashboard, nudge tracking) | `NudgeStoreTests`, via others |
| Router | `AIRouter` (gate → route → budget → outbound → call → ledger) | `AIRouterTests` (5) |
| Cost/budget | `ModelCost`, `BudgetPolicy` | `ModelCostTests`, budget test |
| Providers | `FireworksProvider`, `AnthropicProvider`, `AppleOnDeviceProvider` (real Foundation Models API) | `FireworksParseTests` |
| Notes | `NoteDrafter` (sensitive → bland fallback) | `NoteDrafterTests` (2) |
| Nudges | `NudgeEngine` (meeting/quiet/cap/sustained/logged/dismissal-backoff) | `NudgeEngineTests` (8) |
| Dashboard | `DashboardBuilder` (+ CSV) | `DashboardTests` |

## Acceptance evidence (from PLAN §11)

- ✅ **Sensitive content never leaves the machine:** `AIRouterTests.testSensitiveContentNeverSent`
  seeds "PIP"/"salary", asserts the provider is never called and the phrase appears in **no**
  recorded outbound payload (the local outbound-payload log the plan asks for).
- ✅ **Every cloud call is in the ledger with tokens + cost:** `testSuccessfulCallIsLedgered`;
  budget cap → `refused_budget` (`testBudgetCapRefusesCall`).
- ✅ **Nudges stay under the cap and stop poking dismissed contexts:** `NudgeEngineTests`.
- ⚠️ **Per-client transcript splits with timestamped rationale** (the hour-long-call example) is
  scaffolded (economy-tier `transcript_split` job routes through the router; `transcript_utterances`
  carry offsets) but the end-to-end split→suggestion wiring is thin — see below.

## Divergences / decisions (see DECISIONS.md)

- **Apple on-device rung is really wired** to the shipped Foundation Models SDK (compiles;
  runtime-gated). Guided generation with `@Generable` is the remaining refinement.
- **Anthropic structured output** passed via the system prompt (the `output_config` shape is an
  unverified build-time check).
- **TidyAI gained TidyIngest + TidyUnderstand dependencies** (HTTP reuse + gate) — module-map to update.

## Deferred / thin (flagged)

- **Transcript splitting → per-client meeting_segment suggestions** is not fully wired end-to-end
  (the router job + data exist; the parser that turns an economy-tier split response into multiple
  `meeting_segment` suggestions is a follow-up). The suggestion engine already emits
  `meeting_segment` for classified meeting sessions.
- **On-device guided generation** (`@Generable` structs) and **calibration sampling** (decaying
  Claude second-opinion) are scaffolded via config but not implemented as loops.
- All live cloud/on-device calls are unproven without keys + macOS 26 Apple Intelligence; the router,
  gate, budget, ledger, cost, and parsing are fully tested with fakes/fixtures.

## Notes for the project-wide review

- Run independent checks: correctness (does the ladder/gate/budget behave?), test coverage (what's
  untested beyond the known compile-only OS layers?), and plan adherence (guardrails G1–G9).
- Known compile-only (untested) surfaces: `LiveCapture` OS adapters, live HTTP `URLSessionHTTPClient`,
  `AppleOnDeviceProvider` runtime path, all SwiftUI views, and the `App/` shell.
