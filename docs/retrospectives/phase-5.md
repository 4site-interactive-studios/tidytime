# Phase 5 retrospective — Recap & rules

**Date:** 2026-07-24 · **Status:** ✅ logic complete, tests green (98 total, +17) · **Commit:** `feat(phase-5)`

## What shipped (code-complete + unit-tested)

| Area | Type(s) | Tested by |
|---|---|---|
| Schema | `v1-understand` (entity_signals, suggestions, decisions, pools, resolution_questions, daily_rollups) | via DAO tests |
| Tokenizer | `Tokenizer` | `TokenizerTests` |
| Classification | `Classifier` (rung 1 rules + rung 2 lexical), `EntityBootstrap`, `DayClassifier` | `ClassifierTests` (4), `EntityBootstrapTests`, `DayClassifierTests` |
| Learning | `DecisionRecorder` (reassign → user_confirmed signal) | `DecisionRecorderTests` |
| Questions | `ResolutionQuestionGenerator` | `ResolutionQuestionTests` |
| Sensitivity | `SensitivityGate` (G2, fails closed) | `SensitivityGateTests` (2) |
| Rounding | `RoundingPolicy` | `RoundingPolicyTests` |
| Suggestions | `SuggestionEngine` (standalone/pool/new-task/gap analysis) | `SuggestionEngineTests` (4) |
| Recap | `RecapAssembler` (read model + rollup) | `RecapAssemblerTests` |

This is the first end-to-end "what did I miss today?" — **before any AI**. `RecapView` (SwiftUI) is
compile-only.

## Divergences / decisions (see DECISIONS.md)

- **Pooling now rolls up all non-empty pools at recap** (was ≥15 only) — a test surfaced that
  scattered sub-threshold project work would otherwise evaporate.
- Rung 2 ambiguity guard: a tie between different clients returns nil → becomes a question.
- Rounding keeps a minimum of one increment (6 min → 15, flagged rounded).

## Deferred to manual verification

- The "reconcile a real day in under ten minutes, and a forgotten billable block reaches Productive"
  acceptance needs the live app + real data. The pipeline (classify → suggest → recap read model) is
  tested with synthetic sessions; the human copy-paste loop and the recap window UX are unproven.

## Notes for Phase 6 (Intelligence)

- Add `v1-ai` migration (ai_calls, nudges). Build `TidyAI`: the `AIProvider` protocol + router
  (single metered call site), on-device (Foundation Models, `@Generable`, availability-gated),
  Fireworks + Anthropic clients (reuse HTTP), the usage ledger, and budget caps.
- The **SensitivityGate already exists** (Phase 5) — wire it in front of every cloud payload and add
  the outbound-payload-log guardrail test (seed a sensitive phrase, assert it appears in no payload).
- Note generation, transcript splitting, nudges, and the dashboard (from `ai_calls`) land here.
- The classification ladder's rungs 1–2 are done; rung 3–5 plug in as higher fall-through tiers via
  the router, invoked from `DayClassifier` (keep TidyUnderstand independent of TidyAI — inject a
  protocol).
